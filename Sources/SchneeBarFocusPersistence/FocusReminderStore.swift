import Foundation
import SchneeBarCore
import SchneeBarFocusCore

/// One reminder per private file. The caller owns the directory and one
/// actor per file. No OS effects, cross-process lock or legacy migration.
public actor FocusReminderStore {
    public enum Command: Sendable {
        case setEnabled(Bool), replan(Calendar), claim(ticketID: UUID, calendar: Calendar)
    }
    public enum StoreError: Error, Equatable, Sendable {
        case existingRecord, staleReminder, invalidBackingFile, payloadTooLarge
    }
    public struct Result: Equatable, Sendable {
        public let state: FocusReminderState
        public let claimed: FocusReminderSchedule.Occurrence?
    }

    public static let maximumRecordBytes = 16 * 1024
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

    public func load() throws -> FocusReminderState? {
        guard fileURL.isFileURL else { throw StoreError.invalidBackingFile }
        let data: Data?
        do {
            data = try read(fileURL)
        } catch BoundedRegularFileReadError.unsafeBackingFile {
            throw StoreError.invalidBackingFile
        } catch BoundedRegularFileReadError.payloadTooLarge {
            throw StoreError.payloadTooLarge
        }
        guard let data else { return nil }
        guard data.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        return try JSONDecoder().decode(FocusReminderState.self, from: data)
    }

    public func create(schedule: FocusReminderSchedule, origin: FocusReminderState.Origin = .native) throws -> FocusReminderState {
        guard try load() == nil else { throw StoreError.existingRecord }
        let state = FocusReminderState(schedule: schedule, origin: origin)
        try save(state)
        return state
    }

    /// Read, mutate and commit without suspension. Expose a claimed
    /// occurrence only after persisting its consumption and clearing ticket.
    public func apply(id: UUID, command: Command, at now: Date) throws -> Result {
        guard let old = try load(), old.schedule.id == id else { throw StoreError.staleReminder }
        var next = old
        var claimed: FocusReminderSchedule.Occurrence?
        switch command {
        case .setEnabled(let value): try next.setEnabled(value)
        case .replan(let calendar): try next.replan(at: now, calendar: calendar)
        case .claim(let ticketID, let calendar): claimed = try next.claim(ticketID: ticketID, at: now, calendar: calendar)
        }
        if next != old { try save(next) }
        return Result(state: next, claimed: claimed)
    }

    private func save(_ state: FocusReminderState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        try write(data, fileURL)
    }
}
