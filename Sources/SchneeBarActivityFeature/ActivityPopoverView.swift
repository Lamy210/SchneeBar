import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

public struct ActivityPopoverView: View {
    private let title: String
    private let items: [ActivityItem]
    private let surfaceStyle: SchneeSurfaceStyle

    public init(
        title: String = "Developer Activity",
        items: [ActivityItem],
        surfaceStyle: SchneeSurfaceStyle = .adaptive
    ) {
        self.title = title
        self.items = items
        self.surfaceStyle = surfaceStyle
    }

    public var body: some View {
        let summary = ActivitySummary(items: items)

        VStack(alignment: .leading, spacing: 14) {
            header(summary: summary)

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "No activity",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing needs your attention.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(items) { item in
                            ActivityRow(item: item)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: 360)
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(.primary)
        .schneeSurface(surfaceStyle)
    }

    @ViewBuilder
    private func header(summary: ActivitySummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(summary.menuBarLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if summary.failed > 0 {
                Label("\(summary.failed)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption.weight(.semibold))
            } else if summary.running > 0 {
                Label("\(summary.running)", systemImage: "circle.dotted.circle")
                    .foregroundStyle(.blue)
                    .font(.caption.weight(.semibold))
            } else if summary.waiting > 0 {
                Label("\(summary.waiting)", systemImage: "clock.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.repository)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    Text(item.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch item.state {
        case .success: "checkmark.circle.fill"
        case .running: "circle.dotted.circle"
        case .failed: "xmark.octagon.fill"
        case .waiting: "clock.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .success: .green
        case .running: .blue
        case .failed: .red
        case .waiting: .orange
        }
    }
}
