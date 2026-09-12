import SchneeBarGitHubFeature
import SchneeBarWidgetFeature
import SwiftUI

struct SettingsView: View {
    let model: WidgetRuntimeModel
    @Bindable var githubModel: GitHubConnectionsRuntimeModel

    @Environment(\.openURL) private var openURL
    @State private var pendingDisconnectID: UUID?

    var body: some View {
        Form {
            Section("SchneeBar") {
                LabeledContent("Status", value: "Phase 2")
                LabeledContent("Platform", value: "macOS 15+")
            }

            WidgetSettingsView(
                descriptors: model.orderedDescriptors,
                configuration: model.configuration,
                onSetEnabled: { descriptor, isEnabled in
                    model.setEnabled(isEnabled, for: descriptor)
                },
                onSetRepresentation: { descriptor, representation in
                    model.setRepresentation(representation, for: descriptor)
                },
                onMove: { id, offset in
                    model.moveWidget(id: id, offset: offset)
                }
            )

            GitHubConnectionsView(
                connections: githubModel.connectionCards,
                onAdd: {
                    githubModel.beginOnboarding(defaultClientID: bundledGitHubClientID)
                },
                onRefresh: { id in
                    Task { @MainActor in
                        await githubModel.refresh(profileID: id)
                    }
                },
                onManage: { id in
                    pendingDisconnectID = id
                },
                onSetEnabled: { id, isEnabled in
                    githubModel.setEnabled(isEnabled, profileID: id)
                }
            )
        }
        .formStyle(.grouped)
        .frame(
            minWidth: 680,
            idealWidth: 720,
            maxWidth: 820,
            minHeight: 520,
            idealHeight: 680,
            maxHeight: 820
        )
        .padding()
        .sheet(isPresented: $githubModel.isPresentingOnboarding) {
            GitHubConnectionOnboardingView(
                draft: $githubModel.onboardingDraft,
                phase: githubModel.onboardingPhase,
                onConnect: {
                    githubModel.connectDraft()
                },
                onOpenVerificationPage: { url in
                    openURL(url)
                },
                onCancel: {
                    githubModel.cancelOnboarding()
                }
            )
            .interactiveDismissDisabled(githubModel.onboardingIsActive)
        }
        .confirmationDialog(
            "Manage GitHub Connection",
            isPresented: Binding(
                get: { pendingDisconnectID != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDisconnectID = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let id = pendingDisconnectID {
                Button("Disconnect", role: .destructive) {
                    pendingDisconnectID = nil
                    Task { @MainActor in
                        await githubModel.disconnect(profileID: id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDisconnectID = nil
            }
        } message: {
            Text("Disconnecting removes the stored credential from macOS Keychain and deletes this local SchneeBar connection profile. It does not uninstall the GitHub App.")
        }
    }

    private var bundledGitHubClientID: String? {
        guard let rawValue = Bundle.main.object(
            forInfoDictionaryKey: "SchneeBarGitHubClientID"
        ) as? String else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
