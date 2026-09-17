import SchneeBarCore
import SchneeBarDesignSystem
import SwiftUI

enum ActivityDetailRowInteraction: Equatable {
    case disclosure
    case link(URL)
    case none
}

func activityDetailRowInteraction(_ row: ActivityDetailRow) -> ActivityDetailRowInteraction {
    if !row.children.isEmpty {
        return .disclosure
    }
    if let destinationURL = row.destinationURL {
        return .link(destinationURL)
    }
    return .none
}

func deliveryTimelineConfidenceLabel(
    _ confidence: DeliveryTimelineConfidence
) -> String {
    switch confidence {
    case .exact: "Exact correlation"
    case .high: "High-confidence correlation"
    case .medium: "Medium-confidence correlation"
    case .unknown: "Correlation unavailable"
    }
}

func deliveryTimelineUnavailableMessage(
    for status: DeliveryTimelineStatus
) -> String? {
    switch status {
    case .correlated:
        nil
    case .evidenceUnavailable:
        "Correlation evidence unavailable"
    case .temporarilyUnavailable:
        "Delivery timeline temporarily unavailable"
    }
}

func deliveryTimelineEventIconName(
    _ event: DeliveryTimelineEvent
) -> String {
    activityDetailIconName(for: event.state)
}

func activityDetailIconName(for state: ActivityDetailState) -> String {
    switch state {
    case .success: "checkmark.circle.fill"
    case .running: "circle.dotted.circle"
    case .failed: "xmark.octagon.fill"
    case .waiting: "clock.fill"
    case .neutral: "minus.circle.fill"
    }
}

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
            if let timeline = detail.deliveryTimeline {
                deliverySection(timeline)
                Divider()
                Text("Jobs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

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

    private func deliverySection(
        _ timeline: DeliveryTimelineSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Delivery")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(deliveryTimelineConfidenceLabel(timeline.confidence))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let unavailableMessage = deliveryTimelineUnavailableMessage(for: timeline.status) {
                Label(
                    unavailableMessage,
                    systemImage: timeline.status == .temporarilyUnavailable
                        ? "exclamationmark.triangle"
                        : "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(timeline.events) { event in
                        deliveryEventRow(event)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func deliveryEventRow(
        _ event: DeliveryTimelineEvent
    ) -> some View {
        if let destinationURL = event.destinationURL {
            Link(destination: destinationURL) {
                deliveryEventContent(event, showsExternalLink: true)
            }
            .buttonStyle(.plain)
            .help("Open delivery event")
        } else {
            deliveryEventContent(event, showsExternalLink: false)
        }
    }

    private func deliveryEventContent(
        _ event: DeliveryTimelineEvent,
        showsExternalLink: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: deliveryTimelineEventIconName(event))
                .foregroundStyle(iconColor(for: event.state))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let detail = event.detail {
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
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func detailRow(_ row: ActivityDetailRow) -> some View {
        switch activityDetailRowInteraction(row) {
        case .disclosure:
            DisclosureGroup {
                VStack(spacing: 2) {
                    ForEach(row.children) { child in
                        detailChildRow(child)
                            .padding(.leading, 20)
                    }
                }
            } label: {
                detailRowContent(row, showsExternalLink: false)
            }
        case let .link(destinationURL):
            Link(destination: destinationURL) {
                detailRowContent(row, showsExternalLink: true)
            }
            .buttonStyle(.plain)
            .help("Open job")
        case .none:
            detailRowContent(row, showsExternalLink: false)
        }
    }

    @ViewBuilder
    private func detailChildRow(_ row: ActivityDetailRow) -> some View {
        if let destinationURL = row.destinationURL {
            Link(destination: destinationURL) {
                detailRowContent(row, showsExternalLink: true)
            }
            .buttonStyle(.plain)
            .help("Open job")
        } else {
            detailRowContent(row, showsExternalLink: false)
        }
    }

    private func detailRowContent(
        _ row: ActivityDetailRow,
        showsExternalLink: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activityDetailIconName(for: row.state))
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
