import Foundation
import SchneeBarCore
import SchneeBarFocusCore

/// Native reminder inventory. One actor owns a new private file, never a
/// single-reminder file or Runner storage. No OS notification effects.
public actor FocusReminderCollectionStore {
    public static let maximumEntries = 64
    public static let maximumOutboxEntries = 128
    public static let maximumRecordBytes = 256 * 1024

    public enum StoreError: Error, Equatable, Sendable {
        case invalidTitle, capacityExceeded, duplicateIdentity, staleReminder
        case unsupportedVersion, invalidBackingFile, payloadTooLarge
        case outboxFull, staleOutbox, invalidOutbox
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
        public fileprivate(set) var outbox: [FocusReminderOutboxRecord] = []
        fileprivate init() {}
        private enum CodingKeys: String, CodingKey { case version, entries, outbox }

        public init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            let version = try record.decode(Int.self, forKey: .version)
            guard version == 1 || version == 2 else { throw StoreError.unsupportedVersion }
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
            if version == 1 {
                guard !record.contains(.outbox) else { throw StoreError.invalidOutbox }
            } else {
                outbox = try record.decode([FocusReminderOutboxRecord].self, forKey: .outbox)
                guard outbox.count <= FocusReminderCollectionStore.maximumOutboxEntries else {
                    throw StoreError.outboxFull
                }
                var recordIDs = Set<UUID>()
                var ticketIDs = Set<UUID>()
                for intent in outbox {
                    guard recordIDs.insert(intent.id).inserted,
                          ticketIDs.insert(intent.ticketID).inserted,
                          entries.contains(where: {
                              $0.id == intent.reminderID && $0.state.enabled && $0.state.origin == .native
                          }) else { throw StoreError.invalidOutbox }
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var record = encoder.container(keyedBy: CodingKeys.self)
            try record.encode(2, forKey: .version)
            try record.encode(entries, forKey: .entries)
            try record.encode(outbox, forKey: .outbox)
        }
    }

    public enum Command: Sendable {
        case rename(String), remove, update(FocusReminderStore.Command)
    }

    public struct Result: Equatable, Sendable {
        public let snapshot: Snapshot
        public let claimed: FocusReminderSchedule.Occurrence?
        public let claimedSnooze: FocusReminderState.SnoozeTicket?
        public let enqueued: FocusReminderOutboxRecord?
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

    /// A changed rule is a new schedule identity. Preserve the title and
    /// enabled intent, but do not carry the old occurrence cursor or ticket.
    /// A failed validation, replan or write cannot revoke the old record.
    public func replaceRule(id: UUID, rule: FocusReminderSchedule.Rule,
                            at now: Date, calendar: Calendar) throws -> Entry {
        var snapshot = try load()
        guard let index = snapshot.entries.firstIndex(where: { $0.id == id }) else {
            throw StoreError.staleReminder
        }
        let previous = snapshot.entries[index]
        guard previous.state.origin == .native else { throw FocusReminderState.StateError.importedInactive }
        let schedule = try FocusReminderSchedule(rule: rule)
        // Compare canonical rules, not the randomly generated candidate ID.
        guard schedule.rule != previous.state.schedule.rule else { return previous }
        guard !snapshot.entries.contains(where: { $0.id == schedule.id }) else {
            throw StoreError.duplicateIdentity
        }
        var state = FocusReminderState(schedule: schedule, origin: previous.state.origin)
        try state.setEnabled(previous.state.enabled)
        if state.enabled { try state.replan(at: now, calendar: calendar) }
        let replacement = try Entry(title: previous.title, state: state)
        snapshot.entries[index] = replacement
        // An edited rule replaces the reminder identity. Cancel its queued
        // intents in the same commit, before any OS-side cancellation.
        snapshot.outbox.removeAll { $0.reminderID == id }
        snapshot.entries.sort { $0.id.uuidString < $1.id.uuidString }
        try save(snapshot)
        return replacement
    }

    /// Removing an entry revokes its ticket in the same transaction. All
    /// state operations remain gated by the existing FocusReminderState.
    public func apply(id: UUID, command: Command, at now: Date) throws -> Result {
        let old = try load()
        guard let index = old.entries.firstIndex(where: { $0.id == id }) else { throw StoreError.staleReminder }
        var next = old
        var claimed: FocusReminderSchedule.Occurrence?
        var claimedSnooze: FocusReminderState.SnoozeTicket?
        var enqueued: FocusReminderOutboxRecord?
        switch command {
        case .rename(let title):
            guard Entry.validTitle(title) else { throw StoreError.invalidTitle }
            next.entries[index].title = title
        case .remove:
            next.entries.remove(at: index)
            next.outbox.removeAll { $0.reminderID == id }
        case .update(let action):
            switch action {
            case .setEnabled(let value):
                try next.entries[index].state.setEnabled(value)
                if !value { next.outbox.removeAll { $0.reminderID == id } }
            case .replan(let calendar): try next.entries[index].state.replan(at: now, calendar: calendar)
            case .claim(let ticketID, let calendar):
                claimed = try next.entries[index].state.claim(ticketID: ticketID, at: now, calendar: calendar)
                // A newer regular claim supersedes any older pending snooze.
                next.outbox.removeAll { $0.reminderID == id && $0.kind == .snooze }
                if let claimed {
                    let intent = FocusReminderOutboxRecord(
                        reminderID: id, ticketID: ticketID, kind: .regular,
                        deadline: claimed.date, claimedAt: now
                    )
                    try Self.enqueue(intent, into: &next)
                    enqueued = intent
                }
            case .snooze(let sourceTicketID, let seconds):
                try next.entries[index].state.snooze(sourceTicketID: sourceTicketID, seconds: seconds, at: now)
                // A user snooze action makes an unacknowledged original
                // delivery obsolete; never replay it after restart.
                next.outbox.removeAll {
                    $0.reminderID == id && $0.ticketID == sourceTicketID && $0.kind == .regular
                }
            case .claimSnooze(let ticketID):
                claimedSnooze = try next.entries[index].state.claimSnooze(ticketID: ticketID, at: now)
                if let claimedSnooze {
                    let intent = FocusReminderOutboxRecord(
                        reminderID: id, ticketID: ticketID, kind: .snooze,
                        deadline: claimedSnooze.deadline, claimedAt: now
                    )
                    try Self.enqueue(intent, into: &next)
                    enqueued = intent
                }
            }
        }
        if next != old { try save(next) }
        return Result(snapshot: next, claimed: claimed, claimedSnooze: claimedSnooze, enqueued: enqueued)
    }

    /// Acknowledgement means adapter acceptance, NOT user presentation.
    /// A failure to persist leaves the intent queued for an idempotent retry.
    public func acknowledge(outboxID: UUID) throws -> Snapshot {
        var snapshot = try load()
        guard snapshot.outbox.contains(where: { $0.id == outboxID }) else {
            throw StoreError.staleOutbox
        }
        snapshot.outbox.removeAll { $0.id == outboxID }
        try save(snapshot)
        return snapshot
    }

    private static func enqueue(_ intent: FocusReminderOutboxRecord, into snapshot: inout Snapshot) throws {
        guard snapshot.outbox.count < maximumOutboxEntries else { throw StoreError.outboxFull }
        guard !snapshot.outbox.contains(where: { $0.id == intent.id || $0.ticketID == intent.ticketID }) else {
            throw StoreError.invalidOutbox
        }
        snapshot.outbox.append(intent)
    }

    private func save(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= Self.maximumRecordBytes else { throw StoreError.payloadTooLarge }
        try write(bytes, fileURL)
    }
}
