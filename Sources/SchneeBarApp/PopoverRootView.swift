import AppKit
import SchneeBarActivityFeature
import SchneeBarWidgetFeature
import SwiftUI

struct PopoverRootView: View {
    let model: WidgetRuntimeModel

    var body: some View {
        VStack(spacing: 8) {
            WidgetOverviewView(snapshots: model.snapshots)

            Divider()
                .padding(.horizontal, 12)

            ActivityPopoverView(items: [])

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
}
