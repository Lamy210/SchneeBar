import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

public struct WidgetOverviewView: View {
    private let snapshots: [WidgetSnapshot]
    private let diagnosticsByWidgetID: [WidgetID: WidgetRuntimeDiagnostic]
    private let surfaceStyle: SchneeSurfaceStyle

    public init(
        snapshots: [WidgetSnapshot],
        diagnosticsByWidgetID: [WidgetID: WidgetRuntimeDiagnostic] = [:],
        surfaceStyle: SchneeSurfaceStyle = .adaptive
    ) {
        self.snapshots = snapshots
        self.diagnosticsByWidgetID = diagnosticsByWidgetID
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
                    WidgetRow(
                        snapshot: snapshot,
                        diagnostic: diagnosticsByWidgetID[snapshot.descriptor.id]
                    )
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
    let diagnostic: WidgetRuntimeDiagnostic?

    private var isStale: Bool {
        diagnostic?.indicatesStaleReading(for: snapshot) == true
    }

    private var lastUpdatedDescription: String {
        guard let lastSucceededAt = diagnostic?.lastSucceededAt else {
            return "Update failed · last reading"
        }
        return "Update failed · last updated \(lastSucceededAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: snapshot.content().systemImage ?? "circle.fill")
                    .foregroundStyle(isStale ? Color.orange : tint)
                    .frame(width: 18)

                Text(snapshot.descriptor.displayName)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(snapshot.content().text)
                    .foregroundStyle(isStale ? Color.orange : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if isStale {
                Label(lastUpdatedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("widget-stale-\(snapshot.descriptor.id.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isStale
                ? "\(snapshot.content().accessibilityLabel). Stale reading. \(lastUpdatedDescription)"
                : snapshot.content().accessibilityLabel
        )
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
