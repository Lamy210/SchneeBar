import SchneeBarActivityFeature
import SchneeBarPreviewSupport
import SchneeBarWidgetFeature
import SwiftUI

@main
struct SchneeBarVisualHarnessApp: App {
    var body: some Scene {
        WindowGroup("SchneeBar Visual Harness") {
            VisualHarnessView()
        }
        .defaultSize(width: 800, height: 680)
    }
}

private struct VisualHarnessView: View {
    @State private var activityScenario: ActivityFixtureScenario = .mainFailure
    @State private var widgetScenario: WidgetFixtureScenario = .critical
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

                Picker("Appearance", selection: $appearance) {
                    Text("Light").tag(ColorScheme.light)
                    Text("Dark").tag(ColorScheme.dark)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .frame(width: 260)

            ScrollView {
                VStack(spacing: 16) {
                    WidgetOverviewView(snapshots: widgetScenario.snapshots)

                    ActivityPopoverView(items: activityScenario.items)
                }
                .padding(24)
            }
            .environment(\.colorScheme, appearance)
            .frame(maxWidth: 400)

            Spacer()
        }
        .padding(24)
    }
}
