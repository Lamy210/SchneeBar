import SchneeBarCore
import SwiftUI

public struct WidgetSettingsView: View {
    private let descriptors: [WidgetDescriptor]
    private let configuration: SchneeBarCore.WidgetConfiguration
    private let onSetEnabled: (WidgetDescriptor, Bool) -> Void
    private let onSetRepresentation: (WidgetDescriptor, WidgetRepresentationKind?) -> Void
    private let onMove: (WidgetID, Int) -> Void

    public init(
        descriptors: [WidgetDescriptor],
        configuration: SchneeBarCore.WidgetConfiguration,
        onSetEnabled: @escaping (WidgetDescriptor, Bool) -> Void,
        onSetRepresentation: @escaping (WidgetDescriptor, WidgetRepresentationKind?) -> Void,
        onMove: @escaping (WidgetID, Int) -> Void
    ) {
        self.descriptors = descriptors
        self.configuration = configuration
        self.onSetEnabled = onSetEnabled
        self.onSetRepresentation = onSetRepresentation
        self.onMove = onMove
    }

    public var body: some View {
        Section("Menu Bar Widgets") {
            if descriptors.isEmpty {
                ContentUnavailableView(
                    "No widgets available",
                    systemImage: "rectangle.topthird.inset.filled",
                    description: Text("Registered widgets will appear here.")
                )
            } else {
                ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
                    widgetRow(descriptor, index: index)
                }
            }

            Text("Critical and attention states may temporarily move ahead of your manual order.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func widgetRow(_ descriptor: WidgetDescriptor, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(
                    descriptor.displayName,
                    isOn: Binding(
                        get: { configuration.isEnabled(descriptor) },
                        set: { onSetEnabled(descriptor, $0) }
                    )
                )

                Spacer(minLength: 12)

                HStack(spacing: 4) {
                    Button {
                        onMove(descriptor.id, -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Move up")

                    Button {
                        onMove(descriptor.id, 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == descriptors.count - 1)
                    .help("Move down")
                }
            }

            Picker(
                "Menu bar style",
                selection: Binding<WidgetRepresentationKind?>(
                    get: { configuration.preference(for: descriptor.id)?.representation },
                    set: { onSetRepresentation(descriptor, $0) }
                )
            ) {
                Text("Default").tag(nil as WidgetRepresentationKind?)
                Text("Compact").tag(WidgetRepresentationKind.compact as WidgetRepresentationKind?)
                Text("Normal").tag(WidgetRepresentationKind.normal as WidgetRepresentationKind?)
            }
            .pickerStyle(.segmented)
            .disabled(!configuration.isEnabled(descriptor))

            Text("Critical states automatically use the critical representation when available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
