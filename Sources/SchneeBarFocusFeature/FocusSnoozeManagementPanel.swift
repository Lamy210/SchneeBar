import Foundation
import SchneeBarFocusPersistence
import SwiftUI

/// Explicit local owner boundary for a future developer preview. The store
/// re-reads the durable snapshot at the moment of each cancellation; a row
/// presented earlier is never used as authorization.
public actor FocusSnoozeManagementCoordinator {
    private let store: FocusReminderCollectionStore

    public init(store: FocusReminderCollectionStore) {
        self.store = store
    }

    public func load() async throws -> FocusSnoozeStatusPresentation {
        let snapshot = try await store.load()
        return FocusSnoozeStatusPresentation(snapshot: snapshot)
    }

    /// Only a still-pending Snooze can be removed. No OS requests are sent,
    /// retracted, or acknowledged here.
    public func cancelPending(reminderID: UUID, ticketID: UUID) async throws
        -> FocusSnoozeStatusPresentation {
        let snapshot = try await store.cancelPendingSnooze(reminderID: reminderID, ticketID: ticketID)
        return FocusSnoozeStatusPresentation(snapshot: snapshot)
    }
}

/// Isolated developer-only UI. This is intentionally not connected to
/// SchneeBarApp or UserNotifications. Only local pending Snoozes get a
/// destructive control; queued/outbox entries have NO cancel action.
@MainActor
public struct FocusSnoozeManagementPanel: View {
    private let coordinator: FocusSnoozeManagementCoordinator

    @State private var rows: [FocusSnoozeStatusRow] = []
    @State private var busy = false
    @State private var hasLoaded = false
    @State private var feedback: String?

    public init(coordinator: FocusSnoozeManagementCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage scheduled Snoozes")
                .font(.headline)
            Text("Only Snoozes not yet submitted for notification can be removed here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .accessibilityLabel(feedback)
            }

            if busy && !hasLoaded {
                ProgressView("Loading Snoozes")
            } else if hasLoaded && rows.isEmpty {
                Text("No cancellable or unconfirmed Snoozes")
                    .foregroundStyle(.secondary)
            } else if hasLoaded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.title)
                                    .font(.body)
                                Text(row.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.deadline, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                if row.phase == .pending {
                                    Button("Remove pending Snooze") {
                                        Task { await cancel(row) }
                                    }
                                    .disabled(busy)
                                    .accessibilityLabel("Remove pending Snooze for \(row.title)")
                                    .accessibilityHint("Removes only the local unsubmitted Snooze schedule.")
                                } else {
                                    Text("No cancellation action: system submission may have occurred.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refresh() }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            rows = try await coordinator.load().rows
            hasLoaded = true
            feedback = nil
        } catch {
            // Never leave an old actionable row visible after load failure.
            rows = []
            hasLoaded = false
            feedback = "Unable to load Snoozes. No changes were made."
        }
    }

    private func cancel(_ row: FocusSnoozeStatusRow) async {
        guard !busy, row.phase == .pending else { return }
        busy = true
        defer { busy = false }
        do {
            let updated = try await coordinator.cancelPending(
                reminderID: row.id.reminderID, ticketID: row.id.ticketID
            )
            rows = updated.rows
            feedback = "Pending Snooze removed from the local schedule."
        } catch {
            // State could have advanced into Outbox since the UI rendered.
            // Reload and show a neutral failure, never falsely claim OS cancel.
            do {
                rows = try await coordinator.load().rows
                hasLoaded = true
                feedback = "Snooze changed or cancellation failed. Review the current status."
            } catch {
                rows = []
                hasLoaded = false
                feedback = "Unable to verify Snooze state. No cancellation is confirmed."
            }
        }
    }
}
