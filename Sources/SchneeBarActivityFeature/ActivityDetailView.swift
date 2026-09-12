import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

public struct ActivityDetailView: View {
    private let item: ActivityItem
    private let detail: ActivityDetailSnapshot?
    private let isLoading: Bool
    private let errorMessage: String?
    private let onBack: () -> Void
    private let onRetry: () -> Void
    private let surfaceStyle: SchneeSurfaceStyle

    public init(
        item: ActivityItem,
        detail: ActivityDetailSnapshot?,
        isLoading: Bool,
        errorMessage: String?,
        onBack: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        surfaceStyle: SchneeSurfaceStyle = .adaptive
    ) {
        self.item = item
        self.detail = detail
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onBack = onBack
        self.onRetry = onRetry
        self.surfaceStyle = surfaceStyle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else if let detail {
                detailContent(detail)
            } else {
                ContentUnavailableView(
                    "No job details",
                    systemImage: "info.circle",
                    description: Text("This activity does not expose job-level detail.")
                )
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(.primary)
        .schneeSurface(surfaceStyle)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back to Developer Activity")
            .accessibilityLabel("Back to Developer Activity")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.repository)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let destinationURL = item.destinationURL {
                Link(destination: destinationURL) {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(.plain)
                .help("Open workflow run")
                .accessibilityLabel("Open workflow run")
            }
        }
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading jobs…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(minHeight: 80)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Job details unavailable", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry", action: onRetry)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 90)
    }

    private func detailContent(_ detail: ActivityDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if detail.rows.isEmpty {
                ContentUnavailableView(
                    "No jobs",
                    systemImage: "checklist",
                    description: Text("GitHub returned no jobs for this workflow run.")
                )
                .frame(minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(detail.rows) { row in
                            detailRow(row)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: 360)
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ row: ActivityDetailRow) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: row.state))
                .foregroundStyle(iconColor(for: row.state))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if row.destinationURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())

        if let destinationURL = row.destinationURL {
            Link(destination: destinationURL) {
                content
            }
            .buttonStyle(.plain)
            .help("Open job")
        } else {
            content
        }
    }

    private func iconName(for state: ActivityDetailState) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .running: "circle.dotted.circle"
        case .failed: "xmark.octagon.fill"
        case .waiting: "clock.fill"
        case .neutral: "minus.circle.fill"
        }
    }

    private func iconColor(for state: ActivityDetailState) -> Color {
        switch state {
        case .success: .green
        case .running: .blue
        case .failed: .red
        case .waiting: .orange
        case .neutral: .secondary
        }
    }
}
