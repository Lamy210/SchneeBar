import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let backlogOrigin = Date(timeIntervalSince1970: 1_700_000_000)
private let backlogCalendar = Calendar(identifier: .gregorian)

private func withBacklogStore(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: path), path)
}

private func enqueueBacklogReminder(
    _ store: FocusReminderCollectionStore, secondsUntilDue: TimeInterval
) async throws -> FocusReminderOutboxRecord {
    let due = backlogOrigin.addingTimeInterval(secondsUntilDue)
    let entry = try await store.add(title: "Private reminder", rule: .once(due))
    _ = try await store.apply(
        id: entry.id, command: .update(.setEnabled(true)), at: backlogOrigin
    )
    let planned = try await store.apply(
        id: entry.id, command: .update(.replan(backlogCalendar)), at: backlogOrigin
    )
    let ticket = try #require(
        planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending
    )
    let claimed = try await store.apply(
        id: entry.id,
        command: .update(.claim(ticketID: ticket.id, calendar: backlogCalendar)),
        at: due
    )
    return try #require(claimed.enqueued)
}

@Test func focusBacklogEmptyInventoryHasFullCapacity() async throws {
    try await withBacklogStore { store, _ in
        let snapshot = try await store.load()
        let diagnostic = try snapshot.outboxBacklogDiagnostics(
            at: backlogOrigin, agedAfter: 300
        )
        #expect(diagnostic.queuedCount == 0)
        #expect(diagnostic.remainingCapacity == FocusReminderCollectionStore.maximumOutboxEntries)
        #expect(diagnostic.agedCount == 0)
        #expect(diagnostic.futureClaimCount == 0)
        #expect(diagnostic.oldestClaimedAt == nil)
        #expect(!diagnostic.isAtCapacity)
    }
}

@Test func focusBacklogAgeThresholdIsInclusiveAndReadOnly() async throws {
    try await withBacklogStore { store, path in
        let first = try await enqueueBacklogReminder(store, secondsUntilDue: 60)
        let second = try await enqueueBacklogReminder(store, secondsUntilDue: 120)
        let before = try Data(contentsOf: path)
        let snapshot = try await store.load()

        // Claim ages are 340 and 280 seconds.
        let report = try snapshot.outboxBacklogDiagnostics(
            at: backlogOrigin.addingTimeInterval(400), agedAfter: 300
        )
        #expect(report.queuedCount == 2)
        #expect(report.remainingCapacity == 126)
        #expect(report.agedCount == 1)
        #expect(report.futureClaimCount == 0)
        #expect(report.oldestClaimedAt == first.claimedAt)
        #expect(first.claimedAt < second.claimedAt)

        let exactBoundary = try snapshot.outboxBacklogDiagnostics(
            at: backlogOrigin.addingTimeInterval(420), agedAfter: 300
        )
        #expect(exactBoundary.agedCount == 2)
        #expect(try Data(contentsOf: path) == before)
        #expect(try await store.load() == snapshot)
    }
}

@Test func focusBacklogFutureClaimIsNotTreatedAsAgedOrEligibleToRetry() async throws {
    try await withBacklogStore { store, _ in
        _ = try await enqueueBacklogReminder(store, secondsUntilDue: 60)
        _ = try await enqueueBacklogReminder(store, secondsUntilDue: 120)
        let snapshot = try await store.load()
        let report = try snapshot.outboxBacklogDiagnostics(
            at: backlogOrigin.addingTimeInterval(100), agedAfter: 50
        )
        #expect(report.queuedCount == 2)
        #expect(report.agedCount == 0)
        #expect(report.futureClaimCount == 1)
        #expect(report.remainingCapacity == 126)
        #expect(try await store.load() == snapshot)
    }
}

@Test func focusBacklogInvalidInputsFailClosed() async throws {
    try await withBacklogStore { store, _ in
        let snapshot = try await store.load()
        for invalid in [-1.0, Double.nan, Double.infinity] {
            #expect(throws: FocusReminderOutboxDiagnosticsError.invalidAgeThreshold) {
                try snapshot.outboxBacklogDiagnostics(
                    at: backlogOrigin, agedAfter: invalid
                )
            }
        }
        #expect(throws: FocusReminderOutboxDiagnosticsError.invalidObservationDate) {
            try snapshot.outboxBacklogDiagnostics(
                at: Date(timeIntervalSince1970: .infinity), agedAfter: 300
            )
        }
    }
}


@Test func focusBacklogAtHardCapacityReportsZeroRemainingSlots() async throws {
    try await withBacklogStore { store, _ in
        let due = backlogOrigin.addingTimeInterval(60)
        let entry = try await store.add(title: "Private", rule: .once(due))
        _ = try await store.apply(
            id: entry.id, command: .update(.setEnabled(true)), at: backlogOrigin
        )
        let saved = try await store.load()
        var envelope = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        let records = (0..<FocusReminderCollectionStore.maximumOutboxEntries).map { _ in
            FocusReminderOutboxRecord(
                reminderID: entry.id, ticketID: UUID(), kind: .regular,
                deadline: due, claimedAt: due
            )
        }
        envelope["outbox"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(records)
        )
        let full = try JSONDecoder().decode(
            FocusReminderCollectionStore.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: envelope)
        )
        let report = try full.outboxBacklogDiagnostics(
            at: due.addingTimeInterval(300), agedAfter: 300
        )
        #expect(report.queuedCount == 128)
        #expect(report.remainingCapacity == 0)
        #expect(report.isAtCapacity)
        #expect(report.agedCount == 128)
        #expect(report.futureClaimCount == 0)
        #expect(report.oldestClaimedAt == due)
        // Synthetic input is never written back to the store.
        #expect(try await store.load() == saved)
    }
}
