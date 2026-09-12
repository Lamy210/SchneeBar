import SchneeBarCore
import SwiftUI

public struct ActivityPopoverView: View {
    private let title: String
    private let items: [ActivityItem]

    public init(title: String = "Developer Activity", items: [ActivityItem]) {
        self.title = title
        self.items = items
    }

    public var body: some View {
        let summary = ActivitySummary(items: items)

        VStack(alignment: .leading, spacing: 14) {
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
                }
            }

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    "No activity",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing needs your attention.")
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        ActivityRow(item: item)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .modifier(AdaptiveSchneeSurface())
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
                    Text(item.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
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

private struct AdaptiveSchneeSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }
}
