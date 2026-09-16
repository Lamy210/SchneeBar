import SwiftUI

public enum GitHubRepositorySelectionPresentationMode: String, CaseIterable, Hashable, Sendable {
    case allAccessible
    case selected

    public var label: String {
        switch self {
        case .allAccessible:
            return "All accessible repositories"
        case .selected:
            return "Selected repositories"
        }
    }
}

public enum GitHubRepositoryActivityAccessPresentation: Equatable, Sendable {
    case available
    case unverified
    case unavailable

    fileprivate var statusLabel: String? {
        switch self {
        case .available:
            return nil
        case .unverified:
            return "Unverified"
        case .unavailable:
            return "Unavailable"
        }
    }

    fileprivate var badgeSystemImage: String {
        switch self {
        case .available:
            return "checkmark.circle"
        case .unverified:
            return "questionmark.circle"
        case .unavailable:
            return "xmark.circle"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .available:
            return .secondary
        case .unverified:
            return .orange
        case .unavailable:
            return .red
        }
    }
}

public struct GitHubRepositoryActivityAccessModel: Equatable, Sendable {
    public let actions: GitHubRepositoryActivityAccessPresentation
    public let reviewRequests: GitHubRepositoryActivityAccessPresentation
    public let checks: GitHubRepositoryActivityAccessPresentation

    public init(
        actions: GitHubRepositoryActivityAccessPresentation,
        reviewRequests: GitHubRepositoryActivityAccessPresentation,
        checks: GitHubRepositoryActivityAccessPresentation
    ) {
        self.actions = actions
        self.reviewRequests = reviewRequests
        self.checks = checks
    }
}

public struct GitHubRepositoryOptionModel: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let fullName: String
    public let isPrivate: Bool
    public let activityAccess: GitHubRepositoryActivityAccessModel

    public init(
        id: Int64,
        fullName: String,
        isPrivate: Bool,
        activityAccess: GitHubRepositoryActivityAccessModel
    ) {
        self.id = id
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.activityAccess = activityAccess
    }
}

public struct GitHubConnectionManagementModel: Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let accountLogin: String
    public let repositories: [GitHubRepositoryOptionModel]

    public init(
        id: UUID,
        displayName: String,
        host: String,
        accountLogin: String,
        repositories: [GitHubRepositoryOptionModel]
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.accountLogin = accountLogin
        self.repositories = repositories
    }
}

public struct GitHubConnectionManagementView: View {
    private let model: GitHubConnectionManagementModel
    @Binding private var selectionMode: GitHubRepositorySelectionPresentationMode
    @Binding private var selectedRepositoryIDs: Set<Int64>
    private let onRefresh: () -> Void
    private let onSave: () -> Void
    private let onDisconnect: () -> Void
    private let onCancel: () -> Void

    @State private var searchText = ""
    @State private var isConfirmingDisconnect = false

    public init(
        model: GitHubConnectionManagementModel,
        selectionMode: Binding<GitHubRepositorySelectionPresentationMode>,
        selectedRepositoryIDs: Binding<Set<Int64>>,
        onRefresh: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        _selectionMode = selectionMode
        _selectedRepositoryIDs = selectedRepositoryIDs
        self.onRefresh = onRefresh
        self.onSave = onSave
        self.onDisconnect = onDisconnect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    monitoringSection
                    repositorySection
                    dangerSection
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: 820,
            minHeight: 560,
            idealHeight: 660,
            maxHeight: 760
        )
        .confirmationDialog(
            "Disconnect \(model.displayName)?",
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                onDisconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the local Keychain credential and SchneeBar connection profile. It does not uninstall the GitHub App or change server-side repository access."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.title3.weight(.semibold))
                Text(model.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("@\(model.accountLogin)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                onRefresh()
            } label: {
                Label("Refresh Access", systemImage: "arrow.clockwise")
            }
        }
        .padding(20)
    }

    private var monitoringSection: some View {
        GroupBox("Monitoring scope") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Repositories", selection: $selectionMode) {
                    ForEach(GitHubRepositorySelectionPresentationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectionMode) { oldValue, newValue in
                    guard oldValue == .allAccessible,
                          newValue == .selected,
                          selectedRepositoryIDs.isEmpty
                    else {
                        return
                    }
                    selectedRepositoryIDs = Set(model.repositories.map(\.id))
                }

                Text(monitoringExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var repositorySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Filter repositories", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    if selectionMode == .selected {
                        Menu("Selection") {
                            Button("Select all visible") {
                                selectedRepositoryIDs.formUnion(filteredRepositories.map(\.id))
                            }
                            Button("Clear visible") {
                                selectedRepositoryIDs.subtract(filteredRepositories.map(\.id))
                            }
                        }
                    }
                }

                activityAccessSummary

                if model.repositories.isEmpty {
                    ContentUnavailableView(
                        "Repository inventory unavailable",
                        systemImage: "shippingbox",
                        description: Text(
                            "Refresh this connection to load repositories currently accessible to the GitHub App."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else if filteredRepositories.isEmpty {
                    ContentUnavailableView(
                        "No matching repositories",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different repository name.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRepositories) { repository in
                            repositoryRow(repository)
                            if repository.id != filteredRepositories.last?.id {
                                Divider()
                                    .padding(.leading, 30)
                            }
                        }
                    }
                    .background(.background.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack {
                    Text(repositoryCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        } label: {
            Label("Repositories", systemImage: "shippingbox")
        }
    }

    @ViewBuilder
    private var activityAccessSummary: some View {
        if unavailableActivitySourceCount > 0 || unverifiedActivitySourceCount > 0 {
            HStack(spacing: 12) {
                if unavailableActivitySourceCount > 0 {
                    Label(
                        "\(unavailableActivitySourceCount) unavailable",
                        systemImage: "xmark.circle.fill"
                    )
                    .foregroundStyle(.red)
                }

                if unverifiedActivitySourceCount > 0 {
                    Label(
                        "\(unverifiedActivitySourceCount) unverified",
                        systemImage: "questionmark.circle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)
                Text("Activity source access")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func repositoryRow(_ repository: GitHubRepositoryOptionModel) -> some View {
        let isSelected = selectionMode == .allAccessible
            || selectedRepositoryIDs.contains(repository.id)

        HStack(spacing: 10) {
            if selectionMode == .selected {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { selectedRepositoryIDs.contains(repository.id) },
                        set: { newValue in
                            if newValue {
                                selectedRepositoryIDs.insert(repository.id)
                            } else {
                                selectedRepositoryIDs.remove(repository.id)
                            }
                        }
                    )
                )
                .labelsHidden()
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            Image(systemName: repository.isPrivate ? "lock.fill" : "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(repository.fullName)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                accessBadge("Actions", access: repository.activityAccess.actions)
                accessBadge("Reviews", access: repository.activityAccess.reviewRequests)
                accessBadge("Checks", access: repository.activityAccess.checks)
            }

            if repository.isPrivate {
                Text("Private")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .opacity(isSelected ? 1 : 0.58)
    }

    @ViewBuilder
    private func accessBadge(
        _ surfaceName: String,
        access: GitHubRepositoryActivityAccessPresentation
    ) -> some View {
        if let statusLabel = access.statusLabel {
            Label(surfaceName, systemImage: access.badgeSystemImage)
                .font(.caption2)
                .foregroundStyle(access.tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(access.tint.opacity(0.10), in: Capsule())
                .help("\(surfaceName) access: \(statusLabel.lowercased())")
                .accessibilityLabel("\(surfaceName) access \(statusLabel)")
        }
    }

    private var dangerSection: some View {
        GroupBox("Connection") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disconnect from SchneeBar")
                        .font(.body.weight(.medium))
                    Text("Removes this device's saved credential and local connection profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("Disconnect", role: .destructive) {
                    isConfirmingDisconnect = true
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }

            Spacer()

            Button("Save") {
                onSave()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private var filteredRepositories: [GitHubRepositoryOptionModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return model.repositories
        }
        return model.repositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
        }
    }

    private var monitoredRepositories: [GitHubRepositoryOptionModel] {
        switch selectionMode {
        case .allAccessible:
            return model.repositories
        case .selected:
            return model.repositories.filter { selectedRepositoryIDs.contains($0.id) }
        }
    }

    private var monitoredActivityAccess: [GitHubRepositoryActivityAccessPresentation] {
        monitoredRepositories.flatMap { repository in
            [
                repository.activityAccess.actions,
                repository.activityAccess.reviewRequests,
                repository.activityAccess.checks,
            ]
        }
    }

    private var unavailableActivitySourceCount: Int {
        monitoredActivityAccess.count { $0 == .unavailable }
    }

    private var unverifiedActivitySourceCount: Int {
        monitoredActivityAccess.count { $0 == .unverified }
    }

    private var monitoringExplanation: String {
        switch selectionMode {
        case .allAccessible:
            return "SchneeBar discovers all repositories granted to the GitHub App, while activity polling keeps bounded budgets for Workflows, Review Requests, and Checks."
        case .selected:
            return "Only selected repositories are eligible for developer activity polling. Repository access on GitHub is unchanged."
        }
    }

    private var repositoryCountLabel: String {
        switch selectionMode {
        case .allAccessible:
            return "Monitoring all \(model.repositories.count) accessible repositories"
        case .selected:
            let accessibleIDs = Set(model.repositories.map(\.id))
            return "Monitoring \(selectedRepositoryIDs.intersection(accessibleIDs).count) of \(model.repositories.count) accessible repositories"
        }
    }
}
