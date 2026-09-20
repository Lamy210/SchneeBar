import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

func deliveryHistoryEntryIconName(
    _ entry: DeliveryHistoryEntry
) -> String {
    activityDetailIconName(for: entry.state)
}

public struct DeliveryHistoryView: View {
    private let repository: String
    private let history: DeliveryHistorySnapshot?
    private let isLoading: Bool
    private let errorMessage: String?
    private let onBack: () -> Void
    private let onRetry: () -> Void
    private let surfaceStyle: SchneeSurfaceStyle

    public init(
        repository: String,
        history: DeliveryHistorySnapshot?,
        isLoading: Bool,
        errorMessage: String?,
        onBack: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        surfaceStyle: SchneeSurfaceStyle = .adaptive
    ) {
        self.repository = repository
        self.history = history
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
            } else if let history {
                historyContent(history)
            } else {
                emptyView
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
            .help("Back to workflow detail")
            .accessibilityLabel("Back to workflow detail")

            VStack(alignment: .leading, spacing: 2) {
                Text(repository)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Delivery history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading delivery history…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(minHeight: 80)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Delivery history unavailable",
                systemImage: "exclamationmark.triangle"
            )
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

    @ViewBuilder
    private func historyContent(
        _ history: DeliveryHistorySnapshot
    ) -> some View {
        if history.entries.isEmpty {
            emptyView
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(history.entries) { entry in
                        entryRow(entry)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 360)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No delivery history",
            systemImage: "clock.arrow.circlepath",
            description: Text(
                "GitHub returned no completed workflow runs for this repository."
            )
        )
        .frame(minHeight: 120)
    }

    @ViewBuilder
    private func entryRow(
        _ entry: DeliveryHistoryEntry
    ) -> some View {
        if let destinationURL = entry.destinationURL {
            Link(destination: destinationURL) {
                entryContent(entry, showsExternalLink: true)
            }
            .buttonStyle(.plain)
            .help("Open workflow run")
        } else {
            entryContent(entry, showsExternalLink: false)
        }
    }

    private func entryContent(
        _ entry: DeliveryHistoryEntry,
        showsExternalLink: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: deliveryHistoryEntryIconName(entry))
                .foregroundStyle(iconColor(for: entry.state))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if showsExternalLink {
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func iconColor(
        for state: ActivityDetailState
    ) -> Color {
        switch state {
        case .success: .green
        case .running: .blue
        case .failed: .red
        case .waiting: .orange
        case .neutral: .secondary
        }
    }
}
