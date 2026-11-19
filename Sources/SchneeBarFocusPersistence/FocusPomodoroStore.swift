import Foundation
import SchneeBarCore
import SchneeBarFocusCore

/// One app-owned Pomodoro slot. The caller owns a trusted private directory
/// and one actor instance per file, separate from Runner and countdown data.
public actor FocusPomodoroStore {
    public enum PhaseAction: Sendable {
        case reconcile, pause, resume, advance, cancel
    }

    public enum Command: Sendable {
        case start(id: UUID, plan: FocusPomodoro.Plan)
        case phase(id: UUID, step: Int, action: PhaseAction)
    }

    public enum StoreError: Error, Equatable, Sendable {
        case activeSession, staleSession, stalePhase, duplicateSession, invalidBackingFile, payloadTooLarge
    }

    public struct Result: Equatable, Sendable {
        public let session: FocusPomodoro
        public let completion: FocusPomodoro.Completion?
    }

    public static let maximumRecordBytes = 4096
    private let fileURL: URL
    private let read: @Sendable (URL) throws -> Data?
    private let write: @Sendable (Data, URL) throws -> Void

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, read: {
            try BoundedRegularFileReader.readIfPresent(at: $0, maximumBytes: Self.maximumRecordBytes)
        }, write: { data, url in
            try data.write(to: url, options: .atomic)
        })
    }

    init(fileURL: URL, read: @escaping @Sendable (URL) throws -> Data?,
         write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.fileURL = fileURL
        self.read = read
        self.write = write
    }

    public func load() throws -> FocusPomodoro? {
        guard fileURL.isFileURL else { throw StoreError.invalidBackingFile }
        let bytes: Data?
        do {
            bytes = try read(fileURL)
        } catch BoundedRegularFileReadError.unsafeBackingFile {
            throw StoreError.invalidBackingFile
        } catch BoundedRegularFileReadError.payloadTooLarge {
            throw StoreError.payloadTooLarge
        }
        guard let bytes else { return nil }
        guard bytes.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        return try JSONDecoder().decode(FocusPomodoro.self, from: bytes)
    }

    /// Read, validate, transition, commit, then publish. Even reconcile is
    /// fenced by session and step so a queued observation cannot complete
    /// a newly advanced phase. No notification dispatch here.
    public func apply(_ command: Command, at now: Date) throws -> Result {
        let old = try load()
        var next: FocusPomodoro
        var completion: FocusPomodoro.Completion?
        switch command {
        case .start(let id, let plan):
            if let old {
                guard old.id != id else { throw StoreError.duplicateSession }
                guard old.isFinished || old.isCancelled else { throw StoreError.activeSession }
            }
            next = try FocusPomodoro(id: id, plan: plan, now: now)
        case .phase(let id, let step, let action):
            guard let old, old.id == id else { throw StoreError.staleSession }
            guard old.step == step else { throw StoreError.stalePhase }
            next = old
            switch action {
            case .reconcile: completion = try next.reconcile(at: now)
            case .pause: completion = try next.pause(step: step, at: now)
            case .resume: try next.resume(step: step, at: now)
            case .advance: try next.advance(step: step, at: now)
            case .cancel: completion = try next.cancel(step: step, at: now)
            }
        }
        if next != old {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(next)
            guard bytes.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
            try write(bytes, fileURL)
        }
        return Result(session: next, completion: completion)
    }
}
