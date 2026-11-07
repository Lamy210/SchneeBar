import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

public struct WidgetOverviewView: View {
    private let snapshots: [WidgetSnapshot]
    private let diagnosticsByWidgetID: [WidgetID: WidgetRuntimeDiagnostic]
    private let emptyState: WidgetEmptyDisplayReason
    private let surfaceStyle: SchneeSurfaceStyle

    public init(
        snapshots: [WidgetSnapshot],
        diagnosticsByWidgetID: [WidgetID: WidgetRuntimeDiagnostic] = [:],
        emptyState: WidgetEmptyDisplayReason = .hiddenByPolicy,
        surfaceStyle: SchneeSurfaceStyle = .adaptive
    ) {
        self.snapshots = snapshots
        self.diagnosticsByWidgetID = diagnosticsByWidgetID
        self.emptyState = emptyState
        self.surfaceStyle = surfaceStyle
    }

    private var unavailableDiagnostics: [WidgetRuntimeDiagnostic] {
        let displayedIDs = Set(snapshots.map(\.descriptor.id))
        return diagnosticsByWidgetID.values
            .filter {
                $0.indicatesUnavailableReading
                    && !displayedIDs.contains($0.descriptor.id)
            }
            .sorted {
                if $0.descriptor.defaultOrder != $1.descriptor.defaultOrder {
                    return $0.descriptor.defaultOrder < $1.descriptor.defaultOrder
                }
                return $0.descriptor.id.rawValue < $1.descriptor.id.rawValue
            }
    }

    private var emptyTitle: String {
        switch emptyState {
        case .awaitingWidgets:
            "Loading widgets"
        case .allDisabled:
            "All widgets disabled"
        case .awaitingFirstReading:
            "Waiting for readings"
        case .hiddenByPolicy:
            "No visible widgets"
        }
    }

    private var emptyDescription: String {
        switch emptyState {
        case .awaitingWidgets:
            "Widgets are loading. Open Settings if this persists."
        case .allDisabled:
            "Enable a widget in Settings to see its status."
        case .awaitingFirstReading:
            "Enabled widgets are waiting for their first readings."
        case .hiddenByPolicy:
            "Widgets hidden by policy will appear when they need attention."
        }
    }

    private var emptySystemImage: String {
        switch emptyState {
        case .awaitingWidgets, .awaitingFirstReading:
            "hourglass"
        case .allDisabled:
            "eye.slash"
        case .hiddenByPolicy:
            "rectangle.topthird.inset.filled"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widgets")
                .font(.headline)

            if snapshots.isEmpty && unavailableDiagnostics.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
                .accessibilityIdentifier("widget-empty-\(emptyState.rawValue)")
            } else {
                ForEach(snapshots, id: \.descriptor.id) { snapshot in
                    WidgetRow(
                        snapshot: snapshot,
                        diagnostic: diagnosticsByWidgetID[snapshot.descriptor.id]
                    )
                }
                ForEach(unavailableDiagnostics, id: \.descriptor.id) { diagnostic in
                    UnavailableWidgetRow(diagnostic: diagnostic)
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

private struct UnavailableWidgetRow: View {
    let diagnostic: WidgetRuntimeDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18)

                Text(diagnostic.descriptor.displayName)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text("Unavailable")
                    .foregroundStyle(.orange)
            }

            Text("Measurement failed. SchneeBar will retry automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(diagnostic.descriptor.displayName) unavailable. Measurement failed. Will retry."
        )
        .accessibilityIdentifier("widget-unavailable-\(diagnostic.descriptor.id.rawValue)")
    }
}
