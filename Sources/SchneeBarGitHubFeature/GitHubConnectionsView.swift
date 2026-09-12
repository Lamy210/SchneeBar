import SwiftUI

public enum GitHubConnectionPresentationStatus: Equatable, Sendable {
    case connected(repositoryCount: Int)
    case syncing
    case authenticationRequired
    case ssoRequired
    case networkUnavailable
    case suspended
    case untestedServer(version: String)
    case unavailable

    public var label: String {
        switch self {
        case let .connected(repositoryCount):
            return "Connected · \(repositoryCount) repos"
        case .syncing:
            return "Syncing"
        case .authenticationRequired:
            return "Authentication required"
        case .ssoRequired:
            return "SSO required"
        case .networkUnavailable:
            return "Network or VPN required"
        case .suspended:
            return "Installation suspended"
        case let .untestedServer(version):
            return "GHES \(version) · Untested"
        case .unavailable:
            return "Unavailable"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .connected:
            return "checkmark.circle.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .authenticationRequired, .ssoRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .networkUnavailable:
            return "wifi.slash"
        case .suspended:
            return "pause.circle.fill"
        case .untestedServer:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "xmark.circle.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .connected:
            return .green
        case .syncing:
            return .blue
        case .authenticationRequired, .ssoRequired, .untestedServer:
            return .orange
        case .networkUnavailable, .suspended, .unavailable:
            return .red
        }
    }
}

public struct GitHubConnectionCardModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let accountLogin: String
    public let deploymentLabel: String
    public let repositorySelectionLabel: String
    public let status: GitHubConnectionPresentationStatus
    public let isEnabled: Bool

    public init(
        id: UUID,
        displayName: String,
        host: String,
        accountLogin: String,
        deploymentLabel: String,
        repositorySelectionLabel: String,
        status: GitHubConnectionPresentationStatus,
        isEnabled: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.accountLogin = accountLogin
        self.deploymentLabel = deploymentLabel
        self.repositorySelectionLabel = repositorySelectionLabel
        self.status = status
        self.isEnabled = isEnabled
    }
}

public struct GitHubConnectionsView: View {
    private let connections: [GitHubConnectionCardModel]
    private let onAdd: () -> Void
    private let onRefresh: (UUID) -> Void
    private let onManage: (UUID) -> Void
    private let onSetEnabled: (UUID, Bool) -> Void

    public init(
        connections: [GitHubConnectionCardModel],
        onAdd: @escaping () -> Void,
        onRefresh: @escaping (UUID) -> Void,
        onManage: @escaping (UUID) -> Void,
        onSetEnabled: @escaping (UUID, Bool) -> Void
    ) {
        self.connections = connections
        self.onAdd = onAdd
        self.onRefresh = onRefresh
        self.onManage = onManage
        self.onSetEnabled = onSetEnabled
    }

    public var body: some View {
        Section("GitHub Connections") {
            if connections.isEmpty {
                emptyState
            } else {
                ForEach(connections) { connection in
                    connectionRow(connection)
                }
            }

            Button {
                onAdd()
            } label: {
                Label("Add GitHub Connection", systemImage: "plus")
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "link")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("No GitHub connections")
                    .font(.headline)
                Text("Connect GitHub.com, GHE.com, or a self-hosted GitHub Enterprise Server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func connectionRow(_ connection: GitHubConnectionCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(connection.host)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                Toggle(
                    "Monitor",
                    isOn: Binding(
                        get: { connection.isEnabled },
                        set: { onSetEnabled(connection.id, $0) }
                    )
                )
                .labelsHidden()
                .help(connection.isEnabled ? "Disable monitoring" : "Enable monitoring")
            }

            HStack(spacing: 8) {
                Label(connection.status.label, systemImage: connection.status.systemImage)
                    .foregroundStyle(connection.status.tint)
                    .font(.caption)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("@\(connection.accountLogin)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(connection.deploymentLabel)
                Text("·")
                Text(connection.repositorySelectionLabel)

                Spacer(minLength: 12)

                Button("Refresh") {
                    onRefresh(connection.id)
                }
                .buttonStyle(.borderless)

                Button("Manage") {
                    onManage(connection.id)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(connection.displayName), \(connection.status.label), account \(connection.accountLogin)"
        )
    }
}
