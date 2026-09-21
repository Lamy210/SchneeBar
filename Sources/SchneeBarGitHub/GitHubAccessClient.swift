import Foundation

public struct GitHubAuthenticatedAccount: Equatable, Sendable {
    public let identity: GitHubAccountIdentity
    public let displayName: String?
    public let avatarURL: URL?

    public init(
        identity: GitHubAccountIdentity,
        displayName: String? = nil,
        avatarURL: URL? = nil
    ) {
        self.identity = identity
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

public struct GitHubInstallationAccount: Equatable, Sendable {
    public let id: String
    public let login: String
    public let type: String
    public let avatarURL: URL?

    public init(
        id: String,
        login: String,
        type: String,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.login = login
        self.type = type
        self.avatarURL = avatarURL
    }
}

public struct GitHubInstallation: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let account: GitHubInstallationAccount
    public let repositorySelection: String
    public let permissions: [String: String]
    public let isSuspended: Bool

    public init(
        id: Int64,
        account: GitHubInstallationAccount,
        repositorySelection: String,
        permissions: [String: String],
        isSuspended: Bool
    ) {
        self.id = id
        self.account = account
        self.repositorySelection = repositorySelection
        self.permissions = permissions
        self.isSuspended = isSuspended
    }
}

public struct GitHubRepositoryPermissions: Equatable, Sendable {
    public let admin: Bool
    public let maintain: Bool
    public let push: Bool
    public let triage: Bool
    public let pull: Bool

    public init(
        admin: Bool = false,
        maintain: Bool = false,
        push: Bool = false,
        triage: Bool = false,
        pull: Bool = false
    ) {
        self.admin = admin
        self.maintain = maintain
        self.push = push
        self.triage = triage
        self.pull = pull
    }
}

public struct GitHubRepositoryAccess: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let fullName: String
    public let isPrivate: Bool
    public let webURL: URL
    public let ownerLogin: String
    public let permissions: GitHubRepositoryPermissions
    public let defaultBranch: String?

    public init(
        id: Int64,
        name: String,
        fullName: String,
        isPrivate: Bool,
        webURL: URL,
        ownerLogin: String,
        permissions: GitHubRepositoryPermissions,
        defaultBranch: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.webURL = webURL
        self.ownerLogin = ownerLogin
        self.permissions = permissions
        self.defaultBranch = defaultBranch
    }
}

public enum GitHubInstallationAccessStatus: String, Equatable, Sendable {
    case available
    case suspended
    case forbidden
    case notFound
    case unavailable
}

public struct GitHubInstallationAccess: Equatable, Sendable {
    public let installation: GitHubInstallation
    public let repositories: [GitHubRepositoryAccess]
    public let status: GitHubInstallationAccessStatus

    public init(
        installation: GitHubInstallation,
        repositories: [GitHubRepositoryAccess],
        status: GitHubInstallationAccessStatus = .available
    ) {
        self.installation = installation
        self.repositories = repositories
        self.status = status
    }
}

public struct GitHubAccessInventory: Equatable, Sendable {
    public let account: GitHubAuthenticatedAccount
    public let installations: [GitHubInstallationAccess]

    public init(
        account: GitHubAuthenticatedAccount,
        installations: [GitHubInstallationAccess]
    ) {
        self.account = account
        self.installations = installations
    }
}

public enum GitHubSSOFailureSignal: Equatable, Sendable {
    case required
    case other

    fileprivate init(headerValue: String) {
        let directive = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        self = directive == "required" ? .required : .other
    }
}

public struct GitHubHTTPFailureEvidence: Equatable, Sendable {
    public let statusCode: Int
    public let ssoSignal: GitHubSSOFailureSignal

    public init(
        statusCode: Int,
        ssoSignal: GitHubSSOFailureSignal
    ) {
        self.statusCode = statusCode
        self.ssoSignal = ssoSignal
    }
}

public enum GitHubAccessClientError: Error, Equatable, Sendable {
    case invalidCredential
    case httpStatus(Int)
    case httpFailure(GitHubHTTPFailureEvidence)
    case invalidResponse
    case invalidInstallationID
    case paginationLimitExceeded

    public var statusCode: Int? {
        switch self {
        case let .httpStatus(statusCode):
            return statusCode
        case let .httpFailure(evidence):
            return evidence.statusCode
        case .invalidCredential,
             .invalidResponse,
             .invalidInstallationID,
             .paginationLimitExceeded:
            return nil
        }
    }
}

public struct GitHubAccessClient: Sendable {
    private static let maximumPages = 1_000

    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func authenticatedAccount(
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> GitHubAuthenticatedAccount {
        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.restBaseURL.appendingPathComponent("user", isDirectory: false)
        let payload: UserPayload = try await get(
            url: url,
            connection: connection,
            credential: credential
        )

        guard payload.id > 0, !payload.login.isEmpty else {
            throw GitHubAccessClientError.invalidResponse
        }

        return GitHubAuthenticatedAccount(
            identity: GitHubAccountIdentity(
                id: String(payload.id),
                login: payload.login
            ),
            displayName: payload.name,
            avatarURL: payload.avatarURL.flatMap(URL.init(string:))
        )
    }

    public func installations(
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> [GitHubInstallation] {
        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("user", isDirectory: true)
            .appendingPathComponent("installations", isDirectory: false)

        var page = 1
        var expectedTotal: Int?
        var seenIDs = Set<Int64>()
        var installations: [GitHubInstallation] = []

        while shouldLoadMore(currentCount: installations.count, expectedTotal: expectedTotal) {
            guard page <= Self.maximumPages else {
                throw GitHubAccessClientError.paginationLimitExceeded
            }

            let url = try paginatedURL(baseURL, page: page)
            let payload: InstallationListPayload = try await get(
                url: url,
                connection: connection,
                credential: credential
            )
            expectedTotal = max(0, payload.totalCount)

            guard !payload.installations.isEmpty else {
                break
            }

            let mapped = try payload.installations.map(mapInstallation)
            let newItems = mapped.filter { seenIDs.insert($0.id).inserted }
            guard !newItems.isEmpty else {
                break
            }

            installations.append(contentsOf: newItems)
            page += 1
        }

        return installations
    }

    public func repositories(
        installationID: Int64,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> [GitHubRepositoryAccess] {
        guard installationID > 0 else {
            throw GitHubAccessClientError.invalidInstallationID
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("user", isDirectory: true)
            .appendingPathComponent("installations", isDirectory: true)
            .appendingPathComponent(String(installationID), isDirectory: true)
            .appendingPathComponent("repositories", isDirectory: false)

        var page = 1
        var expectedTotal: Int?
        var seenIDs = Set<Int64>()
        var repositories: [GitHubRepositoryAccess] = []

        while shouldLoadMore(currentCount: repositories.count, expectedTotal: expectedTotal) {
            guard page <= Self.maximumPages else {
                throw GitHubAccessClientError.paginationLimitExceeded
            }

            let url = try paginatedURL(baseURL, page: page)
            let payload: RepositoryListPayload = try await get(
                url: url,
                connection: connection,
                credential: credential
            )
            expectedTotal = max(0, payload.totalCount)

            guard !payload.repositories.isEmpty else {
                break
            }

            let mapped = try payload.repositories.map {
                try mapRepository($0, webBaseURL: endpoints.webBaseURL)
            }
            let newItems = mapped.filter { seenIDs.insert($0.id).inserted }
            guard !newItems.isEmpty else {
                break
            }

            repositories.append(contentsOf: newItems)
            page += 1
        }

        return repositories
    }

    public func inventory(
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> GitHubAccessInventory {
        let account = try await authenticatedAccount(
            connection: connection,
            credential: credential
        )
        let accessibleInstallations = try await installations(
            connection: connection,
            credential: credential
        )

        var installationAccess: [GitHubInstallationAccess] = []
        installationAccess.reserveCapacity(accessibleInstallations.count)

        for installation in accessibleInstallations {
            if installation.isSuspended {
                installationAccess.append(
                    GitHubInstallationAccess(
                        installation: installation,
                        repositories: [],
                        status: .suspended
                    )
                )
                continue
            }

            do {
                let accessibleRepositories = try await repositories(
                    installationID: installation.id,
                    connection: connection,
                    credential: credential
                )
                installationAccess.append(
                    GitHubInstallationAccess(
                        installation: installation,
                        repositories: accessibleRepositories,
                        status: .available
                    )
                )
            } catch let error as GitHubAccessClientError {
                if error.statusCode == 401 {
                    throw error
                }

                if error.statusCode == 403 {
                    installationAccess.append(
                        GitHubInstallationAccess(
                            installation: installation,
                            repositories: [],
                            status: .forbidden
                        )
                    )
                } else if error.statusCode == 404 {
                    installationAccess.append(
                        GitHubInstallationAccess(
                            installation: installation,
                            repositories: [],
                            status: .notFound
                        )
                    )
                } else {
                    installationAccess.append(
                        GitHubInstallationAccess(
                            installation: installation,
                            repositories: [],
                            status: .unavailable
                        )
                    )
                }
            } catch {
                installationAccess.append(
                    GitHubInstallationAccess(
                        installation: installation,
                        repositories: [],
                        status: .unavailable
                    )
                )
            }
        }

        return GitHubAccessInventory(
            account: account,
            installations: installationAccess
        )
    }

    private func get<Response: Decodable>(
        url: URL,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> Response {
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubAccessClientError.invalidCredential
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let apiVersion = apiVersion(for: connection) {
            request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            if let headerValue = response.value(
                forHTTPHeaderField: "X-GitHub-SSO"
            ) {
                throw GitHubAccessClientError.httpFailure(
                    GitHubHTTPFailureEvidence(
                        statusCode: response.statusCode,
                        ssoSignal: GitHubSSOFailureSignal(
                            headerValue: headerValue
                        )
                    )
                )
            }
            throw GitHubAccessClientError.httpStatus(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubAccessClientError.invalidResponse
        }
    }

    private func apiVersion(for connection: GitHubConnection) -> String? {
        if let apiVersion = connection.apiVersion,
           !apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return apiVersion
        }

        switch connection.deploymentKind {
        case .githubDotCom, .gheDotCom:
            return "2026-03-10"
        case .enterpriseServer:
            return nil
        }
    }

    private func paginatedURL(_ url: URL, page: Int) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GitHubAccessClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let result = components.url else {
            throw GitHubAccessClientError.invalidResponse
        }
        return result
    }

    private func shouldLoadMore(currentCount: Int, expectedTotal: Int?) -> Bool {
        expectedTotal.map { currentCount < $0 } ?? true
    }

    private func mapInstallation(_ payload: InstallationPayload) throws -> GitHubInstallation {
        guard payload.id > 0,
              payload.account.id > 0,
              !payload.account.login.isEmpty,
              !payload.account.type.isEmpty
        else {
            throw GitHubAccessClientError.invalidResponse
        }

        return GitHubInstallation(
            id: payload.id,
            account: GitHubInstallationAccount(
                id: String(payload.account.id),
                login: payload.account.login,
                type: payload.account.type,
                avatarURL: payload.account.avatarURL.flatMap(URL.init(string:))
            ),
            repositorySelection: payload.repositorySelection,
            permissions: payload.permissions,
            isSuspended: payload.suspendedAt != nil
        )
    }

    private func mapRepository(
        _ payload: RepositoryPayload,
        webBaseURL: URL
    ) throws -> GitHubRepositoryAccess {
        guard payload.id > 0,
              !payload.name.isEmpty,
              !payload.fullName.isEmpty,
              payload.owner.id > 0,
              !payload.owner.login.isEmpty
        else {
            throw GitHubAccessClientError.invalidResponse
        }

        let webURL = webBaseURL
            .appendingPathComponent(payload.owner.login, isDirectory: true)
            .appendingPathComponent(payload.name, isDirectory: false)

        return GitHubRepositoryAccess(
            id: payload.id,
            name: payload.name,
            fullName: payload.fullName,
            isPrivate: payload.isPrivate,
            webURL: webURL,
            ownerLogin: payload.owner.login,
            permissions: GitHubRepositoryPermissions(
                admin: payload.permissions?.admin ?? false,
                maintain: payload.permissions?.maintain ?? false,
                push: payload.permissions?.push ?? false,
                triage: payload.permissions?.triage ?? false,
                pull: payload.permissions?.pull ?? false
            ),
            defaultBranch: normalizedOptionalBranch(payload.defaultBranch)
        )
    }

    private func normalizedOptionalBranch(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct UserPayload: Decodable {
    let id: Int64
    let login: String
    let name: String?
    let avatarURL: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case name
        case avatarURL = "avatar_url"
    }
}

private struct InstallationListPayload: Decodable {
    let totalCount: Int
    let installations: [InstallationPayload]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case installations
    }
}

private struct InstallationPayload: Decodable {
    let id: Int64
    let account: AccountPayload
    let repositorySelection: String
    let permissions: [String: String]
    let suspendedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case account
        case repositorySelection = "repository_selection"
        case permissions
        case suspendedAt = "suspended_at"
    }
}

private struct AccountPayload: Decodable {
    let id: Int64
    let login: String
    let type: String
    let avatarURL: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case type
        case avatarURL = "avatar_url"
    }
}

private struct RepositoryListPayload: Decodable {
    let totalCount: Int
    let repositories: [RepositoryPayload]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case repositories
    }
}

private struct RepositoryPayload: Decodable {
    let id: Int64
    let name: String
    let fullName: String
    let isPrivate: Bool
    let owner: AccountPayload
    let permissions: RepositoryPermissionPayload?
    let defaultBranch: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case isPrivate = "private"
        case owner
        case permissions
        case defaultBranch = "default_branch"
    }
}

private struct RepositoryPermissionPayload: Decodable {
    let admin: Bool?
    let maintain: Bool?
    let push: Bool?
    let triage: Bool?
    let pull: Bool?
}
