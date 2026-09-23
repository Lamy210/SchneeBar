import SchneeBarGitHubFeature
import SchneeBarWidgetFeature
import SwiftUI

struct SettingsView: View {
    let model: WidgetRuntimeModel
    @Bindable var githubModel: GitHubConnectionsRuntimeModel

    @Environment(\.openURL) private var openURL
    @State private var managingConnectionID: UUID?
    @State private var managementSelectionMode: GitHubRepositorySelectionPresentationMode = .allAccessible
    @State private var managementSelectedRepositoryIDs: Set<Int64> = []

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
                onReauthenticate: { id in
                    githubModel.beginRecovery(profileID: id)
                },
                onManage: presentManagement,
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
                onContinueEnterpriseServer: {
                    githubModel.continueEnterpriseOnboarding()
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
        .sheet(isPresented: recoveryIsPresented) {
            if let context = githubModel.recoveryContext {
                GitHubConnectionRecoveryView(
                    context: context,
                    phase: githubModel.recoveryPhase,
                    onRetry: {
                        githubModel.retryRecovery()
                    },
                    onOpenVerificationPage: { url in
                        openURL(url)
                    },
                    onCancel: {
                        githubModel.cancelRecovery()
                    }
                )
                .interactiveDismissDisabled(githubModel.recoveryIsActive)
            } else {
                ContentUnavailableView(
                    "Connection unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Close this sheet and refresh the GitHub connection list.")
                )
                .frame(minWidth: 520, minHeight: 320)
            }
        }
        .sheet(isPresented: managementIsPresented) {
            if let id = managingConnectionID,
               let managementModel = githubModel.managementModel(profileID: id)
            {
                GitHubConnectionManagementView(
                    model: managementModel,
                    selectionMode: $managementSelectionMode,
                    selectedRepositoryIDs: $managementSelectedRepositoryIDs,
                    onRefresh: {
                        Task { @MainActor in
                            await githubModel.refresh(profileID: id)
                        }
                    },
                    onSave: {
                        Task { @MainActor in
                            let saved = await githubModel.saveValidatedRepositorySelection(
                                profileID: id,
                                mode: managementSelectionMode,
                                selectedRepositoryIDs: managementSelectedRepositoryIDs
                            )
                            if saved {
                                dismissManagement()
                            }
                        }
                    },
                    onDisconnect: {
                        Task { @MainActor in
                            await githubModel.disconnect(profileID: id)
                            dismissManagement()
                        }
                    },
                    onCancel: dismissManagement
                )
            } else {
                ContentUnavailableView(
                    "Connection unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Close this sheet and refresh the GitHub connection list.")
                )
                .frame(minWidth: 520, minHeight: 320)
            }
        }
    }

    private var recoveryIsPresented: Binding<Bool> {
        Binding(
            get: { githubModel.recoveringConnectionID != nil },
            set: { isPresented in
                if !isPresented {
                    githubModel.cancelRecovery()
                }
            }
        )
    }

    private var managementIsPresented: Binding<Bool> {
        Binding(
            get: { managingConnectionID != nil },
            set: { isPresented in
                if !isPresented {
                    dismissManagement()
                }
            }
        )
    }

    private func presentManagement(_ id: UUID) {
        guard let mode = githubModel.repositorySelectionMode(profileID: id) else {
            return
        }
        managementSelectionMode = mode
        managementSelectedRepositoryIDs = githubModel.selectedRepositoryIDs(profileID: id)
        managingConnectionID = id
    }

    private func dismissManagement() {
        managingConnectionID = nil
        managementSelectionMode = .allAccessible
        managementSelectedRepositoryIDs = []
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
