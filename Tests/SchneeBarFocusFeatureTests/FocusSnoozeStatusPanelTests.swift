import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusFeature
import Testing

private let panelStart = Date(timeIntervalSince1970: 1_700_000_000)
private let panelDue = panelStart.addingTimeInterval(60)
private let panelCalendar = Calendar(identifier: .gregorian)

private func withPanelStore(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: file), file)
}

private func makePanelSnooze(
    _ store: FocusReminderCollectionStore, title: String, due: Date
) async throws -> (UUID, FocusReminderState.SnoozeTicket) {
    let entry = try await store.add(title: title, rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: panelStart)
    let planned = try await store.apply(id: entry.id,
        command: .update(.replan(panelCalendar)), at: panelStart)
    let regular = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    _ = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: regular.id, calendar: panelCalendar)), at: due)
    let delayed = try await store.apply(id: entry.id,
        command: .update(.snooze(sourceTicketID: regular.id, seconds: 300)), at: due)
    return (entry.id, try #require(
        delayed.snapshot.entries.first(where: { $0.id == entry.id })?.state.pendingSnooze
    ))
}

@Test func focusSnoozeStatusEmptyPreviewNeverInventsRows() async throws {
    try await withPanelStore { store, file in
        let snapshot = try await store.load()
        let model = FocusSnoozeStatusPresentation(snapshot: snapshot)
        #expect(model.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func focusSnoozeStatusDistinguishesQueuedMayAlreadyBeSent() async throws {
    try await withPanelStore { store, file in
        let (lateID, lateTicket) = try await makePanelSnooze(
            store, title: "Long reminder name for accessibility", due: panelDue.addingTimeInterval(600)
        )
        let (earlyID, earlyTicket) = try await makePanelSnooze(
            store, title: "Morning focus", due: panelDue
        )
        let claimed = try await store.apply(id: lateID,
            command: .update(.claimSnooze(ticketID: lateTicket.id)), at: lateTicket.deadline)
        #expect(claimed.enqueued?.ticketID == lateTicket.id)
        let before = try Data(contentsOf: file)
        let snapshot = try await store.load()
        let model = FocusSnoozeStatusPresentation(snapshot: snapshot)
        #expect(model.rows.count == 2)
        #expect(model.rows.map(\.id.reminderID) == [earlyID, lateID])
        #expect(model.rows.map(\.id.ticketID) == [earlyTicket.id, lateTicket.id])
        #expect(model.rows.map(\.title) == [
            "Morning focus", "Long reminder name for accessibility"
        ])
        #expect(model.rows.map(\.phase) == [.pending, .unacknowledgedOutbox])
        #expect(model.rows[0].statusLabel == "Snooze scheduled")
        #expect(model.rows[1].statusLabel.contains("may already be sent"))
        #expect(try Data(contentsOf: file) == before)
        let reload = try await FocusReminderCollectionStore(fileURL: file).load()
        #expect(FocusSnoozeStatusPresentation(snapshot: reload) == model)
    }
}

@Test func focusSnoozeStatusDoesNotShowAcknowledgedOrDisabledItems() async throws {
    try await withPanelStore { store, _ in
        let (id, snooze) = try await makePanelSnooze(store, title: "Check status", due: panelDue)
        let claimed = try await store.apply(id: id,
            command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        let intent = try #require(claimed.enqueued)
        #expect(FocusSnoozeStatusPresentation(snapshot: claimed.snapshot).rows.count == 1)
        let accepted = try await store.acknowledge(outboxID: intent.id)
        #expect(FocusSnoozeStatusPresentation(snapshot: accepted).rows.isEmpty)
        let (otherID, _) = try await makePanelSnooze(
            store, title: "Disabled reminder", due: panelDue.addingTimeInterval(600)
        )
        #expect(FocusSnoozeStatusPresentation(snapshot: try await store.load()).rows.count == 1)
        let disabled = try await store.apply(id: otherID,
            command: .update(.setEnabled(false)), at: panelDue)
        #expect(FocusSnoozeStatusPresentation(snapshot: disabled.snapshot).rows.isEmpty)
    }
}

@Test func focusSnoozeStatusPanelBuildsFromOneValidatedSnapshot() async throws {
    try await withPanelStore { store, file in
        let (id, _) = try await makePanelSnooze(store, title: "Read only", due: panelDue)
        let snapshot = try await store.load()
        #expect(FocusSnoozeStatusPresentation(snapshot: snapshot).rows.first?.id.reminderID == id)
        let before = try Data(contentsOf: file)
        await MainActor.run { _ = FocusSnoozeStatusPanel(snapshot: snapshot) }
        #expect(try Data(contentsOf: file) == before)
    }
}
