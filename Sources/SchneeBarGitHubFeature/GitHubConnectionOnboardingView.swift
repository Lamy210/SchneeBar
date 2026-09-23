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

public enum GitHubConnectionDraftEndpointError: Error, Equatable, Sendable {
    case serverURLRequired
    case invalidServerURL
    case unsupportedEndpoint(GitHubEndpointResolverError)
}

public extension GitHubConnectionDraft {
    var isReadyToConnect: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && endpointValidationError == nil
    }

    var endpointValidationError: GitHubConnectionDraftEndpointError? {
        do {
            _ = try resolvedWebBaseURL()
            return nil
        } catch let error as GitHubConnectionDraftEndpointError {
            return error
        } catch {
            return .invalidServerURL
        }
    }

    mutating func applyDeploymentDefaults(
        from previousKind: GitHubDeploymentKind,
        to kind: GitHubDeploymentKind
    ) {
        let previousDisplayName = Self.defaultDisplayName(for: previousKind)
        let previousServerURL = Self.defaultServerURL(for: previousKind)

        deploymentKind = kind

        if displayName == previousDisplayName {
            displayName = Self.defaultDisplayName(for: kind)
        }
        if serverURL == previousServerURL {
            serverURL = Self.defaultServerURL(for: kind)
        }
    }

    private static func defaultDisplayName(for kind: GitHubDeploymentKind) -> String {
        switch kind {
        case .githubDotCom:
            return "GitHub.com"
        case .gheDotCom:
            return "Company GitHub"
        case .enterpriseServer:
            return "Internal GitHub"
        }
    }

    private static func defaultServerURL(for kind: GitHubDeploymentKind) -> String {
        switch kind {
        case .githubDotCom:
            return "https://github.com"
        case .gheDotCom:
            return "https://company.ghe.com"
        case .enterpriseServer:
            return "https://github.company.example"
        }
    }

    func resolvedWebBaseURL() throws -> URL {
        let rawURL: String
        switch deploymentKind {
        case .githubDotCom:
            rawURL = "https://github.com"
        case .gheDotCom, .enterpriseServer:
            rawURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty else {
                throw GitHubConnectionDraftEndpointError.serverURLRequired
            }
        }

        guard let webBaseURL = URL(string: rawURL) else {
            throw GitHubConnectionDraftEndpointError.invalidServerURL
        }

        do {
            return try GitHubEndpointResolver.resolve(
                deploymentKind: deploymentKind,
                webBaseURL: webBaseURL
            ).webBaseURL
        } catch let error as GitHubEndpointResolverError {
            throw GitHubConnectionDraftEndpointError.unsupportedEndpoint(error)
        }
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

public struct GitHubEnterpriseServerPreflightPresentation: Equatable, Sendable {
    public let host: String
    public let installedVersion: String
    public let compatibility: GitHubEnterpriseCompatibility

    public init(
        host: String,
        installedVersion: String,
        compatibility: GitHubEnterpriseCompatibility
    ) {
        self.host = host
        self.installedVersion = installedVersion
        self.compatibility = compatibility
    }
}

public enum GitHubConnectionOnboardingPhase: Equatable, Sendable {
    case configuration
    case checkingEnterpriseServer
    case reviewingEnterpriseServer(GitHubEnterpriseServerPreflightPresentation)
    case requestingCode
    case waitingForAuthorization(GitHubDeviceAuthorizationPresentation)
    case finalizing
    case failed(message: String)
}

public struct GitHubConnectionOnboardingView: View {
    @Binding private var draft: GitHubConnectionDraft
    private let phase: GitHubConnectionOnboardingPhase
    private let onConnect: () -> Void
    private let onContinueEnterpriseServer: () -> Void
    private let onOpenVerificationPage: (URL) -> Void
    private let onCancel: () -> Void

    public init(
        draft: Binding<GitHubConnectionDraft>,
        phase: GitHubConnectionOnboardingPhase,
        onConnect: @escaping () -> Void,
        onContinueEnterpriseServer: @escaping () -> Void,
        onOpenVerificationPage: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = draft
        self.phase = phase
        self.onConnect = onConnect
        self.onContinueEnterpriseServer = onContinueEnterpriseServer
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

            case .checkingEnterpriseServer:
                progress(message: "Checking GitHub Enterprise Server compatibility…")
                cancelRow

            case let .reviewingEnterpriseServer(presentation):
                enterpriseServerReview(presentation)

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
                Text("Enterprise Cloud (GHE.com)").tag(GitHubDeploymentKind.gheDotCom)
                Text("Enterprise Server (self-hosted)").tag(GitHubDeploymentKind.enterpriseServer)
            }

            Text(deploymentDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Display name", text: $draft.displayName)

            if draft.deploymentKind != .githubDotCom {
                TextField(serverURLLabel, text: $draft.serverURL)
                    .textContentType(.URL)

                Text(serverURLHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let endpointValidationMessage {
                    Label(endpointValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("GitHub App Client ID", text: $draft.clientID)
                .textContentType(.username)

            Text("The client ID identifies the GitHub App and may be stored in the connection profile. Do not enter a client secret or private key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minHeight: 300)
        .onChange(of: draft.deploymentKind) { previousKind, kind in
            draft.applyDeploymentDefaults(from: previousKind, to: kind)
        }
    }

    @ViewBuilder
    private func enterpriseServerReview(
        _ presentation: GitHubEnterpriseServerPreflightPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review GitHub Enterprise Server", systemImage: "server.rack")
                .font(.headline)

            LabeledContent("Server", value: presentation.host)
            LabeledContent("Version", value: presentation.installedVersion)
            LabeledContent("Compatibility", value: compatibilityLabel(presentation.compatibility))

            if presentation.compatibility != .tested {
                Label(
                    compatibilityWarning(presentation.compatibility),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("Continue to request a one-time Device Flow code from this GitHub Enterprise Server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                Spacer()
                Button("Continue") {
                    onContinueEnterpriseServer()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func compatibilityLabel(
        _ compatibility: GitHubEnterpriseCompatibility
    ) -> String {
        switch compatibility {
        case .tested:
            return "Tested"
        case .olderUntested:
            return "Older than tested range"
        case .newerUntested:
            return "Newer than tested range"
        case .unknownVersion:
            return "Unknown version format"
        }
    }

    private func compatibilityWarning(
        _ compatibility: GitHubEnterpriseCompatibility
    ) -> String {
        switch compatibility {
        case .tested:
            return ""
        case .olderUntested:
            return "This server is older than SchneeBar's tested GHES range. Some GitHub features may be unavailable."
        case .newerUntested:
            return "This server is newer than SchneeBar's tested GHES range. New or changed GitHub behavior may not be covered yet."
        case .unknownVersion:
            return "SchneeBar could not classify this GHES version. Continue only if this is the server you intended to connect."
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
        draft.isReadyToConnect
    }

    private var endpointValidationMessage: String? {
        guard let error = draft.endpointValidationError else {
            return nil
        }

        switch error {
        case .serverURLRequired:
            return "Enter the GitHub server URL."
        case .invalidServerURL:
            return "Enter a valid GitHub server URL."
        case let .unsupportedEndpoint(endpointError):
            switch endpointError {
            case .httpsRequired:
                return "Use an HTTPS URL."
            case .missingHost:
                return "Enter a URL with a valid GitHub host."
            case .credentialsNotAllowed:
                return "Remove the username or password from the server URL."
            case .queryOrFragmentNotAllowed:
                return "Remove query parameters or fragments from the server URL."
            case .pathNotAllowed:
                return "Enter only the GitHub server origin, without an additional path."
            case .nonStandardPortNotAllowed:
                return "Hosted GitHub connections must use the standard HTTPS port."
            case .invalidGitHubDotComHost:
                return "GitHub.com connections must use https://github.com."
            case .invalidGHEHost:
                return "Use a GHE.com web host such as https://company.ghe.com, not an API host."
            }
        }
    }

    private var deploymentDescription: String {
        switch draft.deploymentKind {
        case .githubDotCom:
            return "GitHub-hosted accounts and repositories on github.com."
        case .gheDotCom:
            return "GitHub Enterprise Cloud with data residency on your enterprise's dedicated GHE.com subdomain."
        case .enterpriseServer:
            return "A self-hosted GitHub Enterprise Server instance operated by your organization."
        }
    }

    private var serverURLLabel: String {
        switch draft.deploymentKind {
        case .githubDotCom:
            return "GitHub URL"
        case .gheDotCom:
            return "GHE.com URL"
        case .enterpriseServer:
            return "Enterprise Server URL"
        }
    }

    private var serverURLHelpText: String {
        switch draft.deploymentKind {
        case .githubDotCom:
            return "SchneeBar uses https://github.com."
        case .gheDotCom:
            return "Enter the web URL users open, such as https://company.ghe.com. Do not enter an api.*.ghe.com host."
        case .enterpriseServer:
            return "Enter the HTTPS origin users open in a browser, such as https://github.company.example. Custom HTTPS ports are supported."
        }
    }
}
