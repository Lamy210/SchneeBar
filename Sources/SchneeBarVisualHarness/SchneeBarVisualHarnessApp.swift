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
        .defaultSize(width: 1180, height: 760)
    }
}

private struct VisualHarnessView: View {
    @State private var activityScenario: ActivityFixtureScenario = .mainFailure
    @State private var widgetScenario: WidgetFixtureScenario = .critical
    @State private var githubScenario: GitHubConnectionsFixture = .multiConnection
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
                            onManage: { _ in },
                            onSetEnabled: { _, _ in }
                        )
                    }
                    .formStyle(.grouped)
                    .frame(width: 660)
                }
                .padding(24)
            }
            .environment(\.colorScheme, appearance)
            .frame(maxWidth: 700)

            Spacer()
        }
        .padding(24)
    }
}
