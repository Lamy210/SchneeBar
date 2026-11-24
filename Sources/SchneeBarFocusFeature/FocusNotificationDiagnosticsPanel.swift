import Foundation
import SchneeBarFocusNotifications
import SwiftUI

/// Developer-only read-only presentation of bounded macOS evidence counts.
/// No titles, raw identifiers, receipt claims, permissions, or OS actions.
@MainActor
public struct FocusNotificationDiagnosticsPanel: View {
    private let reader: FocusReminderNotificationDiagnosticsReader

    @State private var diagnostics: FocusReminderNotificationDiagnostics?
    @State private var loading = false
    @State private var errorMessage: String?

    public init(reader: FocusReminderNotificationDiagnosticsReader) {
        self.reader = reader
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Notification evidence")
                    .font(.headline)
                Spacer(minLength: 0)
                Button("Refresh evidence") {
                    Task { await refresh() }
                }
                .disabled(loading)
                .accessibilityHint("Reads current local Outbox and macOS evidence. Does not change notifications.")
            }

            Text("Read-only diagnostics. OS lists are not proof of delivery or permission to retry or cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if loading {
                ProgressView("Inspecting notification evidence")
                    .controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .accessibilityLabel(errorMessage)
            }

            if let diagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Durable Outbox records: \(diagnostics.durableOutboxCount)")
                    Text("Observed in OS lists: \(diagnostics.observedOutboxCount)")
                    Text("Without current OS evidence: \(diagnostics.missingSystemEvidenceCount)")
                    Text("Untracked owned identifiers: \(diagnostics.untrackedOwnedIdentifierCount)")
                    Text("Ignored non-Focus identifiers: \(diagnostics.ignoredIdentifierCount)")
                    Text(authorizationLabel(diagnostics.authorization))
                        .foregroundStyle(.secondary)
                    if diagnostics.requiresManualReview {
                        Text("Manual review needed. Missing evidence does not mean notification failure.")
                            .foregroundStyle(.secondary)
                    }
                    if diagnostics.evidenceQuality == .authorizationRestricted {
                        Text("Notification permission is limited or unknown. No delivery inference is possible.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .contain)
            } else if !loading && errorMessage == nil {
                Text("No evidence inspection has completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refresh() }
    }

    private func authorizationLabel(_ status: FocusReminderNotificationAuthorization) -> String {
        switch status {
        case .notDetermined: "Permission: not determined"
        case .denied: "Permission: denied"
        case .authorized: "Permission: authorized"
        case .provisional: "Permission: provisional"
        case .unsupported: "Permission: unsupported"
        }
    }

    private func refresh() async {
        guard !loading else { return }
        // Invalidate stale counts immediately, including across a failing
        // inspection or a new intervening Outbox mutation.
        diagnostics = nil
        errorMessage = nil
        loading = true
        defer { loading = false }
        do {
            diagnostics = try await reader.load()
        } catch {
            diagnostics = nil
            errorMessage = "Evidence could not be verified. Refresh to retry; no notification was changed."
        }
    }
}
