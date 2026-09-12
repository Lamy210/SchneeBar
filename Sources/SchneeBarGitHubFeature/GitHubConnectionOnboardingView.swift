import SchneeBarGitHub
import SwiftUI

public struct GitHubConnectionDraft: Equatable, Sendable {
    public var deploymentKind: GitHubDeploymentKind
    public var displayName: String
    public var serverURL: String
    public var clientID: String

    public init(
        deploymentKind: GitHubDeploymentKind = .githubDotCom,
        displayName: String = "GitHub.com",
        serverURL: String = "https://github.com",
        clientID: String = ""
    ) {
        self.deploymentKind = deploymentKind
        self.displayName = displayName
        self.serverURL = serverURL
        self.clientID = clientID
    }
}

public struct GitHubDeviceAuthorizationPresentation: Equatable, Sendable {
    public let userCode: String
    public let verificationURI: URL
    public let expiresAt: Date

    public init(userCode: String, verificationURI: URL, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
    }
}

public enum GitHubConnectionOnboardingPhase: Equatable, Sendable {
    case configuration
    case requestingCode
    case waitingForAuthorization(GitHubDeviceAuthorizationPresentation)
    case finalizing
    case failed(message: String)
}

public struct GitHubConnectionOnboardingView: View {
    @Binding private var draft: GitHubConnectionDraft
    private let phase: GitHubConnectionOnboardingPhase
    private let onConnect: () -> Void
    private let onOpenVerificationPage: (URL) -> Void
    private let onCancel: () -> Void

    public init(
        draft: Binding<GitHubConnectionDraft>,
        phase: GitHubConnectionOnboardingPhase,
        onConnect: @escaping () -> Void,
        onOpenVerificationPage: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = draft
        self.phase = phase
        self.onConnect = onConnect
        self.onOpenVerificationPage = onOpenVerificationPage
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch phase {
            case .configuration, .failed:
                configurationForm
                if case let .failed(message) = phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                actionRow(connectEnabled: canConnect)

            case .requestingCode:
                progress(message: "Requesting a GitHub authorization code…")
                cancelRow

            case let .waitingForAuthorization(presentation):
                authorizationCode(presentation)
                cancelRow

            case .finalizing:
                progress(message: "Validating account and repository access…")
                cancelRow
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add GitHub Connection")
                .font(.title2.bold())
            Text("Credentials are stored in macOS Keychain. The GitHub App client ID is public metadata, not a secret.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configurationForm: some View {
        Form {
            Picker("GitHub deployment", selection: $draft.deploymentKind) {
                Text("GitHub.com").tag(GitHubDeploymentKind.githubDotCom)
                Text("GHE.com").tag(GitHubDeploymentKind.gheDotCom)
                Text("Enterprise Server").tag(GitHubDeploymentKind.enterpriseServer)
            }

            TextField("Display name", text: $draft.displayName)

            if draft.deploymentKind != .githubDotCom {
                TextField("Server URL", text: $draft.serverURL)
                    .textContentType(.URL)
            }

            TextField("GitHub App Client ID", text: $draft.clientID)
                .textContentType(.username)

            Text("The client ID identifies the GitHub App and may be stored in the connection profile. Do not enter a client secret or private key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minHeight: 250)
        .onChange(of: draft.deploymentKind) { _, kind in
            applyDefaults(for: kind)
        }
    }

    @ViewBuilder
    private func authorizationCode(
        _ presentation: GitHubDeviceAuthorizationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Authorize SchneeBar in GitHub", systemImage: "key.fill")
                .font(.headline)

            Text("Enter this one-time code on the GitHub authorization page:")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(presentation.userCode)
                .font(.system(.title, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
                .padding(.vertical, 8)

            Button("Open GitHub Authorization Page") {
                onOpenVerificationPage(presentation.verificationURI)
            }
            .buttonStyle(.borderedProminent)

            Text(presentation.verificationURI.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            Text("SchneeBar polls only at GitHub's requested interval and backs off when GitHub asks it to slow down.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progress(message: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
    }

    private func actionRow(connectEnabled: Bool) -> some View {
        HStack {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            Spacer()
            Button("Connect") {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!connectEnabled)
        }
    }

    private var cancelRow: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        }
    }

    private var canConnect: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (draft.deploymentKind == .githubDotCom
                || !draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func applyDefaults(for kind: GitHubDeploymentKind) {
        switch kind {
        case .githubDotCom:
            draft.displayName = "GitHub.com"
            draft.serverURL = "https://github.com"
        case .gheDotCom:
            if draft.displayName == "GitHub.com" {
                draft.displayName = "Company GitHub"
            }
            if draft.serverURL == "https://github.com" {
                draft.serverURL = "https://company.ghe.com"
            }
        case .enterpriseServer:
            if draft.displayName == "GitHub.com" {
                draft.displayName = "Internal GitHub"
            }
            if draft.serverURL == "https://github.com" || draft.serverURL.hasSuffix(".ghe.com") {
                draft.serverURL = "https://github.company.example"
            }
        }
    }
}
