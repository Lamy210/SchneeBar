import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let reconciliationOrigin = Date(timeIntervalSince1970: 1_700_000_000)
private let reconciliationCalendar = Calendar(identifier: .gregorian)

private func withReconciliationStore(
    _ body: (FocusReminderCollectionStore) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(FocusReminderCollectionStore(fileURL: dir.appendingPathComponent("reminders.json")))
}

private func enqueueForReconciliation(
    _ store: FocusReminderCollectionStore, secondsUntilDue: TimeInterval
) async throws -> FocusReminderOutboxRecord {
    let due = reconciliationOrigin.addingTimeInterval(secondsUntilDue)
    let entry = try await store.add(title: "Private title", rule: .once(due))
    _ = try await store.apply(id: entry.id,
        command: .update(.setEnabled(true)), at: reconciliationOrigin)
    let planned = try await store.apply(id: entry.id,
        command: .update(.replan(reconciliationCalendar)), at: reconciliationOrigin)
    let ticket = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    let claimed = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: ticket.id, calendar: reconciliationCalendar)), at: due)
    return try #require(claimed.enqueued)
}

@Test func notificationReconciliationSeparatesObservedMissingAndUntracked() async throws {
    try await withReconciliationStore { store in
        let a = try await enqueueForReconciliation(store, secondsUntilDue: 60)
        let b = try await enqueueForReconciliation(store, secondsUntilDue: 120)
        let c = try await enqueueForReconciliation(store, secondsUntilDue: 180)
        let snapshot = try await store.load()
        let aID = FocusReminderNotificationIdentity.identifier(for: a.id)
        let bID = FocusReminderNotificationIdentity.identifier(for: b.id)
        let orphanID = FocusReminderNotificationIdentity.identifier(for: UUID())
        let externalID = "github-delivery-recovery:123"
        let malformedID = FocusReminderNotificationIdentity.prefix + "NOT-A-UUID"
        let plan = try snapshot.reconcileNotificationIdentifiers(
            pending: [aID, aID, externalID],
            delivered: [bID, orphanID, malformedID]
        )

        #expect(plan.observedInSystem == [a, b])
        #expect(plan.missingSystemEvidence == [c])
        #expect(plan.untrackedOwnedIdentifiers == [orphanID])
        #expect(plan.ignoredIdentifierCount == 2)
        #expect(try await store.load() == snapshot)
    }
}

@Test func notificationReconciliationDoesNotAssumeMissingMeansNeverSubmitted() async throws {
    try await withReconciliationStore { store in
        let a = try await enqueueForReconciliation(store, secondsUntilDue: 60)
        let snapshot = try await store.load()
        let unknown = try snapshot.reconcileNotificationIdentifiers(pending: [], delivered: [])
        #expect(unknown.observedInSystem.isEmpty)
        #expect(unknown.missingSystemEvidence == [a])
        #expect(unknown.untrackedOwnedIdentifiers.isEmpty)
        #expect(unknown.ignoredIdentifierCount == 0)

        let observed = try snapshot.reconcileNotificationIdentifiers(
            pending: [], delivered: [FocusReminderNotificationIdentity.identifier(for: a.id)])
        #expect(observed.observedInSystem == [a])

        // Acknowledgement is a separate, explicit durable operation.
        #expect(try await store.load().outbox == [a])
        _ = try await store.acknowledge(outboxID: a.id)
        let afterACK = try await store.load()
        let alreadyDelivered = try afterACK.reconcileNotificationIdentifiers(
            pending: [], delivered: [FocusReminderNotificationIdentity.identifier(for: a.id)])
        #expect(alreadyDelivered.observedInSystem.isEmpty)
        #expect(alreadyDelivered.untrackedOwnedIdentifiers
                == [FocusReminderNotificationIdentity.identifier(for: a.id)])
    }
}

@Test func notificationReconciliationCanonicalNamespaceAndEvidenceLimits() throws {
    let uuid = UUID()
    let good = FocusReminderNotificationIdentity.identifier(for: uuid)
    #expect(FocusReminderNotificationIdentity.parseOwned(good) == uuid)
    #expect(FocusReminderNotificationIdentity.parseOwned(good.uppercased()) == nil)
    #expect(FocusReminderNotificationIdentity.parseOwned(
        FocusReminderNotificationIdentity.prefix + uuid.uuidString) == nil)
    #expect(FocusReminderNotificationIdentity.parseOwned("another.app." + uuid.uuidString) == nil)
    #expect(FocusReminderNotificationIdentity.parseOwned(
        FocusReminderNotificationIdentity.prefix + "malformed") == nil)

    let snapshot = try JSONDecoder().decode(
        FocusReminderCollectionStore.Snapshot.self,
        from: Data("{\"version\":1,\"entries\":[]}".utf8)
    )
    let empty = try snapshot.reconcileNotificationIdentifiers(pending: [], delivered: [])
    #expect(empty.observedInSystem.isEmpty && empty.missingSystemEvidence.isEmpty)
    #expect(empty.untrackedOwnedIdentifiers.isEmpty)
    #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
        try snapshot.reconcileNotificationIdentifiers(pending: [], delivered: [], maximumEvidenceCount: 0)
    }
    #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
        try snapshot.reconcileNotificationIdentifiers(
            pending: [good, good], delivered: [good], maximumEvidenceCount: 2)
    }
    #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
        try snapshot.reconcileNotificationIdentifiers(
            pending: [], delivered: [], maximumEvidenceCount: 65_537)
    }
}
