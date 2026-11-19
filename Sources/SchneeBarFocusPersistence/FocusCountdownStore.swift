import Foundation
import SchneeBarCore
import SchneeBarFocusCore

/// One native countdown slot. One application-owned instance per file.
/// The caller provides a trusted private directory, separate from Runner data.
/// No OS notification or scheduler side effects.
public actor FocusCountdownStore {
    public enum Command: Sendable {
        case start(id: UUID, duration: TimeInterval)
        case reconcile(id: UUID)
        case pause(id: UUID)
        case resume(id: UUID)
        case cancel(id: UUID)
    }

    public enum StoreError: Error, Equatable, Sendable {
        case activeCountdown, staleCountdown, duplicateCountdown, invalidBackingFile, payloadTooLarge
    }

    public struct Result: Equatable, Sendable {
        public let countdown: FocusCountdown
        public let completion: FocusCountdown.Completion?
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

    // Fault injection seam: synchronous operations, no actor reentrancy.
    init(fileURL: URL, read: @escaping @Sendable (URL) throws -> Data?,
         write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.fileURL = fileURL
        self.read = read
        self.write = write
    }

    public func load() throws -> FocusCountdown? {
        guard fileURL.isFileURL else { throw StoreError.invalidBackingFile }
        let bytes: Data?
        do {
            bytes = try read(fileURL)
        } catch BoundedRegularFileReadError.unsafeBackingFile {
            throw StoreError.invalidBackingFile
        } catch BoundedRegularFileReadError.payloadTooLarge {
            throw StoreError.payloadTooLarge
        }
        guard let data = bytes else { return nil }
        guard data.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        return try JSONDecoder().decode(FocusCountdown.self, from: data)
    }

    /// Each operation reads the committed record and writes only a validated
    /// change. A completion is returned only after the write succeeds.
    /// A caller must not replay an uncertain external notification.
    public func apply(_ command: Command, at now: Date) throws -> Result {
        let old = try load()
        var next: FocusCountdown
        var completion: FocusCountdown.Completion?
        switch command {
        case .start(let id, let duration):
            if let old {
                guard old.id != id else { throw StoreError.duplicateCountdown }
                switch old.phase {
                case .running, .paused: throw StoreError.activeCountdown
                case .completed, .cancelled: break
                }
            }
            next = try FocusCountdown(id: id, duration: duration, now: now)
        case .reconcile(let id), .pause(let id), .resume(let id), .cancel(let id):
            guard let old, old.id == id else { throw StoreError.staleCountdown }
            next = old
            switch command {
            case .reconcile: completion = try next.reconcile(at: now)
            case .pause: completion = try next.pause(at: now)
            case .resume: try next.resume(at: now)
            case .cancel: completion = try next.cancel(at: now)
            case .start: preconditionFailure("Unreachable command")
            }
        }

        if next != old {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            guard data.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
            try write(data, fileURL)
        }
        return Result(countdown: next, completion: completion)
    }
}
