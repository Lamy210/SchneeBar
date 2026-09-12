import SchneeBarWidgetFeature
import SwiftUI

struct SettingsView: View {
    let model: WidgetRuntimeModel

    var body: some View {
        Form {
            Section("SchneeBar") {
                LabeledContent("Status", value: "Phase 1")
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

            Section("Developer Activity") {
                Text("GitHub connection and provider settings will live here without leaking provider-specific state into the UI layer.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, minHeight: 420, idealHeight: 520, maxHeight: 640)
        .padding()
    }
}
