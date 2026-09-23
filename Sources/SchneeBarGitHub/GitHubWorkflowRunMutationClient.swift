import Foundation

public enum GitHubWorkflowRunMutationError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidRunID
    case httpStatus(Int)
}

public struct GitHubWorkflowRunMutationClient: Sendable {
    private enum Mutation {
        case rerun
        case cancel

        var pathComponent: String {
            switch self {
            case .rerun:
                return "rerun"
            case .cancel:
                return "cancel"
            }
        }

        var successStatusCode: Int {
            switch self {
            case .rerun:
                return 201
            case .cancel:
                return 202
            }
        }
    }

    private let transport: any GitHubHTTPTransport

    public init(
        transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()
    ) {
        self.transport = transport
    }

    public func rerun(
        runID: Int64,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws {
        try await mutate(
            .rerun,
            runID: runID,
            repository: repository,
            connection: connection,
            credential: credential
        )
    }

    public func cancel(
        runID: Int64,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws {
        try await mutate(
            .cancel,
            runID: runID,
            repository: repository,
            connection: connection,
            credential: credential
        )
    }

    private func mutate(
        _ mutation: Mutation,
        runID: Int64,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws {
        guard runID > 0 else {
            throw GitHubWorkflowRunMutationError.invalidRunID
        }

        let owner = repository.ownerLogin
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = repository.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !name.isEmpty else {
            throw GitHubWorkflowRunMutationError.invalidRepository
        }

        let token = credential.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubWorkflowRunMutationError.invalidCredential
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(runID), isDirectory: true)
            .appendingPathComponent(
                mutation.pathComponent,
                isDirectory: false
            )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        if let apiVersion = GitHubRESTAPIVersionPolicy()
            .headerVersion(for: connection)
        {
            request.setValue(
                apiVersion,
                forHTTPHeaderField: "X-GitHub-Api-Version"
            )
        }

        let (_, response) = try await transport.data(for: request)
        guard response.statusCode == mutation.successStatusCode else {
            throw GitHubWorkflowRunMutationError.httpStatus(
                response.statusCode
            )
        }
    }
}
