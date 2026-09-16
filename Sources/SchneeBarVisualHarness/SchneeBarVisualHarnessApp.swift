import SchneeBarActivityFeature
import SchneeBarGitHubFeature
import SchneeBarPreviewSupport
import SchneeBarWidgetFeature
import SwiftUI

@main
struct SchneeBarVisualHarnessApp: App {
    var body: some Scene {
        WindowGroup("SchneeBar Visual Harness") {
            VisualHarnessView()
        }
        .defaultSize(width: 1180, height: 840)
    }
}

private enum GitHubRecoveryHarnessScenario: String, CaseIterable, Hashable {
    case deviceCode
    case wrongAccount
    case finalizing

    var phase: GitHubConnectionRecoveryPhase {
        switch self {
        case .deviceCode:
            return .waitingForAuthorization(GitHubConnectionRecoveryFixture.authorization)
        case .wrongAccount:
            return .failed(
                message: "GitHub authorized a different account. Sign in as @snow-user and try again."
            )
        case .finalizing:
            return .finalizing
        }
    }
}

private enum GitHubManagementHarnessScenario: String, CaseIterable, Hashable {
    case repositoryMatrix
    case mixedCapabilities

    var model: GitHubConnectionManagementModel {
        switch self {
        case .repositoryMatrix:
            GitHubConnectionManagementFixture.model
        case .mixedCapabilities:
            GitHubConnectionManagementFixture.mixedCapabilityModel
        }
    }

    var selectedRepositoryIDs: Set<Int64> {
        switch self {
        case .repositoryMatrix:
            GitHubConnectionManagementFixture.selectedRepositoryIDs
        case .mixedCapabilities:
            GitHubConnectionManagementFixture.mixedCapabilitySelectedRepositoryIDs
        }
    }
}

private struct VisualHarnessView: View {
    @State private var activityScenario: ActivityFixtureScenario = .mainFailure
    @State private var widgetScenario: WidgetFixtureScenario = .critical
    @State private var githubScenario: GitHubConnectionsFixture = .multiConnection
    @State private var recoveryScenario: GitHubRecoveryHarnessScenario = .deviceCode
    @State private var managementScenario: GitHubManagementHarnessScenario = .repositoryMatrix
    @State private var managementMode: GitHubRepositorySelectionPresentationMode = .selected
    @State private var managementSelectedIDs = GitHubConnectionManagementFixture.selectedRepositoryIDs
    @State private var appearance: ColorScheme = .dark

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Form {
                Picker("Activity", selection: $activityScenario) {
                    ForEach(ActivityFixtureScenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }

                Picker("Widgets", selection: $widgetScenario) {
                    ForEach(WidgetFixtureScenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }

                Picker("GitHub", selection: $githubScenario) {
                    ForEach(GitHubConnectionsFixture.allCases, id: \.rawValue) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }

                Picker("Recovery", selection: $recoveryScenario) {
                    ForEach(GitHubRecoveryHarnessScenario.allCases, id: \.rawValue) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }

                Picker("Capabilities", selection: $managementScenario) {
                    ForEach(GitHubManagementHarnessScenario.allCases, id: \.rawValue) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }
                .onChange(of: managementScenario) { _, newValue in
                    managementSelectedIDs = newValue.selectedRepositoryIDs
                }

                Picker("Repository scope", selection: $managementMode) {
                    ForEach(GitHubRepositorySelectionPresentationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Appearance", selection: $appearance) {
                    Text("Light").tag(ColorScheme.light)
                    Text("Dark").tag(ColorScheme.dark)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .frame(width: 280)

            ScrollView {
                VStack(spacing: 20) {
                    WidgetOverviewView(snapshots: widgetScenario.snapshots)
                        .frame(maxWidth: 400)

                    ActivityPopoverView(items: activityScenario.items)
                        .frame(maxWidth: 400)

                    Form {
                        GitHubConnectionsView(
                            connections: githubScenario.connections,
                            onAdd: {},
                            onRefresh: { _ in },
                            onReauthenticate: { _ in },
                            onManage: { _ in },
                            onSetEnabled: { _, _ in }
                        )
                    }
                    .formStyle(.grouped)
                    .frame(width: 660)

                    GitHubConnectionRecoveryView(
                        context: GitHubConnectionRecoveryFixture.context,
                        phase: recoveryScenario.phase,
                        onRetry: {},
                        onOpenVerificationPage: { _ in },
                        onCancel: {}
                    )
                    .frame(width: 580)

                    GitHubConnectionManagementView(
                        model: managementScenario.model,
                        selectionMode: $managementMode,
                        selectedRepositoryIDs: $managementSelectedIDs,
                        onRefresh: {},
                        onSave: {},
                        onDisconnect: {},
                        onCancel: {}
                    )
                    .frame(width: 700)
                }
                .padding(24)
            }
            .environment(\.colorScheme, appearance)
            .frame(maxWidth: 740)

            Spacer()
        }
        .padding(24)
    }
}
