import Foundation
import SchneeBarGitHub
import Testing

private actor CapabilitySessionCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }
}

private struct CapabilitySessionResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor CapabilitySessionTransport: GitHubHTTPTransport {
    private var responses: [CapabilitySessionResponse]

    init(_ responses: [CapabilitySessionResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? CapabilitySessionResponse("{}", statusCode: 500)
            : responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }
}

@Test
func establishReturnsCapabilityAssessmentFromFreshInventory() async throws {
    let transport = CapabilitySessionTransport(
        capabilitySessionInventoryResponses(actionsPermission: "read")
    )
    let store = CapabilitySessionCredentialStore()
    let coordinator = capabilitySessionCoordinator(transport: transport, store: store)

    let session = try await coordinator.establish(
        connection: try capabilitySessionConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(
        session.capabilities.state(for: .actions, repositoryID: 1001)
            == .available
    )
}

@Test
func restoreRecomputesCapabilityAssessmentFromChangedInventory() async throws {
    let connection = try capabilitySessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let credentialKey = GitHubCredentialKey(
        connectionID: connection.id,
        accountID: identity.id
    )
    let store = CapabilitySessionCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_access"),
        for: credentialKey
    )

    let transport = CapabilitySessionTransport(
        capabilitySessionInventoryResponses(actionsPermission: "read")
            + capabilitySessionInventoryResponses(actionsPermission: nil)
    )
    let coordinator = capabilitySessionCoordinator(transport: transport, store: store)

    let first = try await coordinator.restore(
        connection: connection,
        identity: identity
    )
    let second = try await coordinator.restore(
        connection: connection,
        identity: identity
    )

    #expect(
        first.capabilities.state(for: .actions, repositoryID: 1001)
            == .available
    )
    #expect(
        second.capabilities.state(for: .actions, repositoryID: 1001)
            == .unavailable(.missingPermission)
    )
}

private func capabilitySessionCoordinator(
    transport: CapabilitySessionTransport,
    store: CapabilitySessionCredentialStore
) -> GitHubConnectionSessionCoordinator {
    GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(transport: transport)
    )
}

private func capabilitySessionConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func capabilitySessionInventoryResponses(
    actionsPermission: String?
) -> [CapabilitySessionResponse] {
    let permissions: String
    if let actionsPermission {
        permissions = #"{"actions":"\#(actionsPermission)"}"#
    } else {
        permissions = "{}"
    }

    return [
        CapabilitySessionResponse(capabilitySessionUserJSON()),
        CapabilitySessionResponse(capabilitySessionUserJSON()),
        CapabilitySessionResponse(
            #"{"total_count":1,"installations":[{"id":11,"account":{"id":101,"login":"example-org","type":"Organization"},"repository_selection":"selected","permissions":\#(permissions),"suspended_at":null}]}"#
        ),
        CapabilitySessionResponse(
            #"{"total_count":1,"repositories":[{"id":1001,"name":"private-service","full_name":"example-org/private-service","private":true,"owner":{"id":101,"login":"example-org","type":"Organization"},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#
        ),
    ]
}

private func capabilitySessionUserJSON() -> String {
    #"{"id":42,"login":"octocat","name":null,"avatar_url":null}"#
}
