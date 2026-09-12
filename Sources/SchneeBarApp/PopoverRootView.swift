import AppKit
import SchneeBarActivityFeature
import SchneeBarCore
import SchneeBarWidgetFeature
import SwiftUI

struct PopoverRootView: View {
    private static let activityWidgetID: WidgetID = "developer.activity"

    let model: WidgetRuntimeModel
    let activityModel: ActivityRuntimeModel

    var body: some View {
        VStack(spacing: 8) {
            WidgetOverviewView(snapshots: model.snapshots)

            if activityIsEnabled {
                Divider()
                    .padding(.horizontal, 12)

                ActivityPopoverView(items: activityModel.items)
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 12) {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }

                Spacer(minLength: 12)

                Button("Quit SchneeBar") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var activityIsEnabled: Bool {
        guard let descriptor = model.descriptors.first(where: {
            $0.id == Self.activityWidgetID
        }) else {
            return false
        }
        return model.configuration.isEnabled(descriptor)
    }
}
