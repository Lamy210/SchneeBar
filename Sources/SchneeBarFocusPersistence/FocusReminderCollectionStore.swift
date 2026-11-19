import Foundation
import SchneeBarCore
import SchneeBarFocusCore

/// Native reminder inventory. One actor owns a new private file, never a
/// single-reminder file or Runner storage. No OS notification effects.
public actor FocusReminderCollectionStore {
    public static let maximumEntries = 64
    public static let maximumRecordBytes = 256 * 1024

    public enum StoreError: Error, Equatable, Sendable {
        case invalidTitle, capacityExceeded, duplicateIdentity, staleReminder
        case unsupportedVersion, invalidBackingFile, payloadTooLarge
    }

    public struct Entry: Equatable, Sendable, Codable {
        public fileprivate(set) var title: String
        public fileprivate(set) var state: FocusReminderState
        public var id: UUID { state.schedule.id }

        fileprivate init(title: String, state: FocusReminderState) throws {
            guard Self.validTitle(title) else { throw StoreError.invalidTitle }
            self.title = title
            self.state = state
        }

        fileprivate static func validTitle(_ title: String) -> Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && title.utf8.count <= 512 && title.unicodeScalars.count <= 128
                && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }

        private enum CodingKeys: String, CodingKey { case title, state }
        public init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(title: record.decode(String.self, forKey: .title),
                          state: record.decode(FocusReminderState.self, forKey: .state))
        }
    }

    public struct Snapshot: Equatable, Sendable, Codable {
        public fileprivate(set) var entries: [Entry] = []
        fileprivate init() {}
        private enum CodingKeys: String, CodingKey { case version, entries }

        public init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            guard try record.decode(Int.self, forKey: .version) == 1 else { throw StoreError.unsupportedVersion }
            var list = try record.nestedUnkeyedContainer(forKey: .entries)
            if let count = list.count, count > FocusReminderCollectionStore.maximumEntries {
                throw StoreError.capacityExceeded
            }
            var identities = Set<UUID>()
            while !list.isAtEnd {
                guard entries.count < FocusReminderCollectionStore.maximumEntries else { throw StoreError.capacityExceeded }
                let entry = try list.decode(Entry.self)
                guard identities.insert(entry.id).inserted else { throw StoreError.duplicateIdentity }
                entries.append(entry)
            }
            entries.sort { $0.id.uuidString < $1.id.uuidString }
        }

        public func encode(to encoder: Encoder) throws {
            var record = encoder.container(keyedBy: CodingKeys.self)
            try record.encode(1, forKey: .version)
            try record.encode(entries, forKey: .entries)
        }
    }

    public enum Command: Sendable {
        case rename(String), remove, update(FocusReminderStore.Command)
    }

    public struct Result: Equatable, Sendable {
        public let snapshot: Snapshot
        public let claimed: FocusReminderSchedule.Occurrence?
    }

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

    /// Allocate a fresh identity internally. Callers cannot recycle deleted
    /// IDs. Imported origin must be assigned by the authorized import owner.
    public func add(title: String, rule: FocusReminderSchedule.Rule,
                    origin: FocusReminderState.Origin = .native) throws -> Entry {
        var snapshot = try load()
        guard snapshot.entries.count < Self.maximumEntries else { throw StoreError.capacityExceeded }
        let schedule = try FocusReminderSchedule(rule: rule)
        guard !snapshot.entries.contains(where: { $0.id == schedule.id }) else { throw StoreError.duplicateIdentity }
        let entry = try Entry(title: title, state: .init(schedule: schedule, origin: origin))
        snapshot.entries.append(entry)
        snapshot.entries.sort { $0.id.uuidString < $1.id.uuidString }
        try save(snapshot)
        return entry
    }

    /// Removing an entry revokes its ticket in the same transaction. All
    /// state operations remain gated by the existing FocusReminderState.
    public func apply(id: UUID, command: Command, at now: Date) throws -> Result {
        let old = try load()
        guard let index = old.entries.firstIndex(where: { $0.id == id }) else { throw StoreError.staleReminder }
        var next = old
        var claimed: FocusReminderSchedule.Occurrence?
        switch command {
        case .rename(let title):
            guard Entry.validTitle(title) else { throw StoreError.invalidTitle }
            next.entries[index].title = title
        case .remove:
            next.entries.remove(at: index)
        case .update(let action):
            switch action {
            case .setEnabled(let value): try next.entries[index].state.setEnabled(value)
            case .replan(let calendar): try next.entries[index].state.replan(at: now, calendar: calendar)
            case .claim(let ticketID, let calendar):
                claimed = try next.entries[index].state.claim(ticketID: ticketID, at: now, calendar: calendar)
            }
        }
        if next != old { try save(next) }
        return Result(snapshot: next, claimed: claimed)
    }

    private func save(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        try write(bytes, fileURL)
    }
}
