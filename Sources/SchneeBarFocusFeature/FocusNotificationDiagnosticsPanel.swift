import Foundation
import SchneeBarFocusNotifications
import SwiftUI

/// Developer-only read-only presentation of bounded macOS evidence counts.
/// No titles, raw identifiers, receipt claims, permissions, or OS actions.
@MainActor
public struct FocusNotificationDiagnosticsPanel: View {
    @StateObject private var state: FocusNotificationDiagnosticsViewState

    public init(reader: FocusReminderNotificationDiagnosticsReader) {
        _state = StateObject(wrappedValue: FocusNotificationDiagnosticsViewState(reader: reader))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Notification evidence")
                    .font(.headline)
                Spacer(minLength: 0)
                Button("Refresh evidence") {
                    Task { await state.refresh() }
                }
                .disabled(state.isLoading)
                .accessibilityHint("Reads current local Outbox and macOS evidence. Does not change notifications.")
            }

            Text("Read-only diagnostics. OS lists are not proof of delivery or permission to retry or cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.isLoading {
                ProgressView("Inspecting notification evidence")
                    .controlSize(.small)
            }

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .accessibilityLabel(errorMessage)
            }

            if let diagnostics = state.diagnostics {
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
            } else if !state.isLoading && state.errorMessage == nil {
                Text("No evidence inspection has completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await state.refresh() }
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

}
