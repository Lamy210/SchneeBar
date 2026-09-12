import SchneeBarActivityFeature
import SchneeBarPreviewSupport
import SwiftUI

@main
struct SchneeBarVisualHarnessApp: App {
    var body: some Scene {
        WindowGroup("SchneeBar Visual Harness") {
            VisualHarnessView()
        }
        .defaultSize(width: 760, height: 560)
    }
}

private struct VisualHarnessView: View {
    @State private var scenario: ActivityFixtureScenario = .mainFailure
    @State private var appearance: ColorScheme = .dark

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Form {
                Picker("Scenario", selection: $scenario) {
                    ForEach(ActivityFixtureScenario.allCases) { scenario in
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

            ActivityPopoverView(items: scenario.items)
                .environment(\.colorScheme, appearance)
                .padding(24)

            Spacer()
        }
        .padding(24)
    }
}
