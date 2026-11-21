import Foundation
import SchneeBarCore
import SchneeBarFocusCore

/// One native snapshot and transaction owner. Use a new private file, never
/// the old per-slot files or Runner storage. No notifications or migration.
public actor FocusLedgerStore {
    public enum Command: Sendable {
        case countdown(FocusCountdownStore.Command)
        case pomodoro(FocusPomodoroStore.Command)
    }

    public enum Completion: Equatable, Sendable {
        case countdown(FocusCountdown.Completion)
        case pomodoro(FocusPomodoro.Completion)
    }

    public enum StoreError: Error, Equatable, Sendable {
        case invalidBackingFile, payloadTooLarge, unsupportedVersion, inconsistentHistory, reusedIdentity
    }

    public struct Snapshot: Equatable, Sendable, Codable {
        public fileprivate(set) var countdown: FocusCountdown?
        public fileprivate(set) var pomodoro: FocusPomodoro?
        public fileprivate(set) var history = FocusHistory()

        fileprivate init() {}
        private enum CodingKeys: String, CodingKey { case version, countdown, pomodoro, history }

        public init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            guard try record.decode(Int.self, forKey: .version) == 1 else { throw StoreError.unsupportedVersion }
            countdown = try record.decodeIfPresent(FocusCountdown.self, forKey: .countdown)
            pomodoro = try record.decodeIfPresent(FocusPomodoro.self, forKey: .pomodoro)
            history = try record.decode(FocusHistory.self, forKey: .history)
            // Incomplete current slots cannot have a completed entry. A
            // completed slot may have aged out, but cannot be missing if retained.
            var projected = history
            if let countdown {
                let outcome = try projected.record(completed: countdown)
                if outcome == .incomplete && history.entries.contains(where: { $0.sourceID == countdown.id && $0.step == nil }) {
                    throw StoreError.inconsistentHistory
                }
            }
            if let pomodoro {
                let outcome = try projected.record(completed: pomodoro)
                if history.entries.contains(where: { entry in
                    guard entry.sourceID == pomodoro.id, let step = entry.step else { return false }
                    return step > pomodoro.step || (step == pomodoro.step && outcome == .incomplete)
                }) { throw StoreError.inconsistentHistory }
            }
            guard projected == history else { throw StoreError.inconsistentHistory }
        }

        public func encode(to encoder: Encoder) throws {
            var record = encoder.container(keyedBy: CodingKeys.self)
            try record.encode(1, forKey: .version)
            try record.encodeIfPresent(countdown, forKey: .countdown)
            try record.encodeIfPresent(pomodoro, forKey: .pomodoro)
            try record.encode(history, forKey: .history)
        }
    }

    public struct Result: Equatable, Sendable {
        public let snapshot: Snapshot
        public let completion: Completion?
    }

    public static let maximumRecordBytes = 256 * 1024
    private let fileURL: URL
    private let read: @Sendable (URL) throws -> Data?
    private let write: @Sendable (Data, URL) throws -> Void

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, read: {
            try BoundedRegularFileReader.readIfPresent(at: $0, maximumBytes: Self.maximumRecordBytes)
        }, write: { data, url in try data.write(to: url, options: .atomic) })
    }

    init(fileURL: URL, read: @escaping @Sendable (URL) throws -> Data?,
         write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.fileURL = fileURL
        self.read = read
        self.write = write
    }

    public func load() throws -> Snapshot {
        guard fileURL.isFileURL else { throw StoreError.invalidBackingFile }
        let bytes: Data?
        do {
            bytes = try read(fileURL)
        } catch BoundedRegularFileReadError.unsafeBackingFile {
            throw StoreError.invalidBackingFile
        } catch BoundedRegularFileReadError.payloadTooLarge {
            throw StoreError.payloadTooLarge
        }
        guard let bytes else { return Snapshot() }
        guard bytes.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        return try JSONDecoder().decode(Snapshot.self, from: bytes)
    }

    /// State and retained history are committed in one replacement, before
    /// returning completion. No suspension or second write in the transaction.
    public func apply(_ command: Command, at now: Date) throws -> Result {
        let old = try load()
        var next = old
        var completion: Completion?
        switch command {
        case .countdown(let action):
            if case .start(let id, _) = action,
               old.history.entries.contains(where: { $0.sourceID == id && $0.step == nil }) {
                throw StoreError.reusedIdentity
            }
            let result = try FocusCountdownStore.transition(action, from: old.countdown, at: now)
            next.countdown = result.countdown
            if let event = result.completion {
                try next.history.record(completed: result.countdown)
                completion = .countdown(event)
            }
        case .pomodoro(let action):
            if case .start(let id, _) = action,
               old.history.entries.contains(where: { $0.sourceID == id && $0.step != nil }) {
                throw StoreError.reusedIdentity
            }
            let result = try FocusPomodoroStore.transition(action, from: old.pomodoro, at: now)
            next.pomodoro = result.session
            if let event = result.completion {
                try next.history.record(completed: result.session)
                completion = .pomodoro(event)
            }
        }
        if next != old {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            guard data.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
            try write(data, fileURL)
        }
        return Result(snapshot: next, completion: completion)
    }
}
