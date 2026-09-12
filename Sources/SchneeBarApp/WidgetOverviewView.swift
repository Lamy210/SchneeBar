import SchneeBarCore
import SwiftUI

struct WidgetOverviewView: View {
    let snapshots: [WidgetSnapshot]

    var body: some View {
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Widgets")
                    .font(.headline)

                ForEach(snapshots, id: \.descriptor.id) { snapshot in
                    HStack(spacing: 10) {
                        Image(systemName: snapshot.content().systemImage ?? "circle.fill")
                            .foregroundStyle(tint(for: snapshot.severity))
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }

    private func tint(for severity: WidgetSeverity) -> Color {
        switch severity {
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
