import Foundation
import SwiftUI

public enum GitHubConnectionRecoveryPhase: Equatable, Sendable {
    case requestingCode
    case waitingForAuthorization(GitHubDeviceAuthorizationPresentation)
    case finalizing
    case failed(message: String)
}

public struct GitHubConnectionRecoveryContext: Equatable, Sendable {
    public let connectionID: UUID
    public let displayName: String
    public let host: String
    public let accountLogin: String

    public init(
        connectionID: UUID,
        displayName: String,
        host: String,
        accountLogin: String
    ) {
        self.connectionID = connectionID
        self.displayName = displayName
        self.host = host
        self.accountLogin = accountLogin
    }
}

public struct GitHubConnectionRecoveryView: View {
    private let context: GitHubConnectionRecoveryContext
    private let phase: GitHubConnectionRecoveryPhase
    private let onRetry: () -> Void
    private let onOpenVerificationPage: (URL) -> Void
    private let onCancel: () -> Void

    public init(
        context: GitHubConnectionRecoveryContext,
        phase: GitHubConnectionRecoveryPhase,
        onRetry: @escaping () -> Void,
        onOpenVerificationPage: @escaping (URL) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.phase = phase
        self.onRetry = onRetry
        self.onOpenVerificationPage = onOpenVerificationPage
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch phase {
            case .requestingCode:
                progress(message: "Requesting a GitHub authorization code…")
            case let .waitingForAuthorization(presentation):
                authorizationCode(presentation)
            case .finalizing:
                progress(message: "Validating account and repository access…")
            case let .failed(message):
                failure(message: message)
            }

            cancelRow
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Re-authenticate GitHub")
                .font(.title2.bold())
            Text("\(context.displayName) · @\(context.accountLogin)")
                .font(.headline)
            Text(context.host)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Authorize the same GitHub account to repair this existing connection. Repository and monitoring settings are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

            Text("If GitHub is signed in as another account, switch to @\(context.accountLogin) before approving the request.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func failure(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
    }

    private var cancelRow: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                onCancel()
            }
        }
    }
}
