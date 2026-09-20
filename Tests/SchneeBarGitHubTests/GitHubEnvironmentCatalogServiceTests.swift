import Foundation
import SchneeBarGitHub
import Testing

private actor EnvironmentCatalogCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]
    private var loadCount = 0

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        loadCount += 1
        return values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }

    func recordedLoadCount() -> Int {
        loadCount
    }
}

private actor EnvironmentCatalogTransport: GitHubHTTPTransport {
    private let json: String
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(
        json: String = #"{"total_count":1,"environments":[{"id":301,"name":"production","protection_rules":[],"deployment_branch_policy":null}]}"#,
        statusCode: Int = 200
    ) {
        self.json = json
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func environmentCatalogServiceAuthorizesOnceAndLoadsExactlyOnePage() async throws {
    let transport = EnvironmentCatalogTransport(
        json: """
        {
          "total_count":1,
          "environments":[
            {
              "id":301,
              "name":"production",
              "protection_rules":[],
              "deployment_branch_policy":null
            }
          ]
        }
        """
    )
    let fixture = try await environmentCatalogFixture(transport: transport)

    let catalog = try await fixture.service.environmentCatalog(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository
    )

    #expect(catalog.environments.map(\.name) == ["production"])
    #expect(await fixture.store.recordedLoadCount() == 1)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.path == "/repos/octocat/project/environments")
    #expect(queryValue("per_page", in: request) == "100")
    #expect(queryValue("page", in: request) == "1")
}

@Test
func environmentCatalogServiceChecksCancellationBeforeFeatureRequest() async throws {
    let transport = EnvironmentCatalogTransport()
    let fixture = try await environmentCatalogFixture(transport: transport)

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        return try await fixture.service.environmentCatalog(
            connection: fixture.connection,
            identity: fixture.identity,
            clientID: nil,
            repository: fixture.repository
        )
    }

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func environmentCatalogServicePropagatesClientHTTPFailure() async throws {
    let transport = EnvironmentCatalogTransport(
        json: #"{"message":"Not Found"}"#,
        statusCode: 404
    )
    let fixture = try await environmentCatalogFixture(transport: transport)

    await #expect(throws: GitHubEnvironmentClientError.httpStatus(404)) {
        _ = try await fixture.service.environmentCatalog(
            connection: fixture.connection,
            identity: fixture.identity,
            clientID: nil,
            repository: fixture.repository
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private struct EnvironmentCatalogFixture {
    let service: GitHubEnvironmentCatalogService
    let store: EnvironmentCatalogCredentialStore
    let connection: GitHubConnection
    let identity: GitHubAccountIdentity
    let repository: GitHubRepositoryAccess
}

private func environmentCatalogFixture(
    transport: EnvironmentCatalogTransport
) async throws -> EnvironmentCatalogFixture {
    let connection = GitHubConnection(
        id: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let repository = GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/octocat/project")),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
    let store = EnvironmentCatalogCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_environment_catalog"),
        for: GitHubCredentialKey(
            connectionID: connection.id,
            accountID: identity.id
        )
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store
    )
    let service = GitHubEnvironmentCatalogService(
        sessionCoordinator: coordinator,
        environmentClient: GitHubEnvironmentClient(
            transport: transport
        )
    )
    return EnvironmentCatalogFixture(
        service: service,
        store: store,
        connection: connection,
        identity: identity,
        repository: repository
    )
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          )
    else {
        return nil
    }
    return components.queryItems?
        .first(where: { $0.name == name })?
        .value
}
