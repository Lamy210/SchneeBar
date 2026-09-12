import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

public struct WidgetOverviewView: View {
    private let snapshots: [WidgetSnapshot]
    private let surfaceStyle: SchneeSurfaceStyle

    public init(
        snapshots: [WidgetSnapshot],
        surfaceStyle: SchneeSurfaceStyle = .adaptive
    ) {
        self.snapshots = snapshots
        self.surfaceStyle = surfaceStyle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widgets")
                .font(.headline)

            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No visible widgets",
                    systemImage: "rectangle.topthird.inset.filled",
                    description: Text("Widgets hidden by policy will appear when they need attention.")
                )
            } else {
                ForEach(snapshots, id: \.descriptor.id) { snapshot in
                    WidgetRow(snapshot: snapshot)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(.primary)
        .schneeSurface(surfaceStyle)
    }
}

private struct WidgetRow: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.content().systemImage ?? "circle.fill")
                .foregroundStyle(tint)
                .frame(width: 18)

            Text(snapshot.descriptor.displayName)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(snapshot.content().text)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.content().accessibilityLabel)
    }

    private var tint: Color {
        switch snapshot.severity {
        case .nominal:
            .secondary
        case .active:
            .blue
        case .attention:
            .orange
        case .critical:
            .red
        case .unavailable:
            .gray
        }
    }
}
