import Foundation
import SchneeBarGitHub
import Testing

private actor RestoredAccountCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]
    private var saveCount = 0

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
        values[key] = credential
        saveCount += 1
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }

    func saves() -> Int {
        saveCount
    }
}

private struct RestoredAccountStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor RestoredAccountTransport: GitHubHTTPTransport {
    private var responses: [RestoredAccountStubResponse]

    init(_ responses: [RestoredAccountStubResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? RestoredAccountStubResponse("{}", statusCode: 500)
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
func restoreUsesFreshInventoryAccountMetadataWhenStableIDMatches() async throws {
    let connection = try restoredAccountConnection()
    let expectedIdentity = GitHubAccountIdentity(
        id: "42",
        login: "old-login"
    )
    let transport = RestoredAccountTransport([
        RestoredAccountStubResponse(restoredAccountUserJSON(id: 42, login: "old-login")),
        RestoredAccountStubResponse(restoredAccountUserJSON(id: 42, login: "renamed-login")),
        RestoredAccountStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = RestoredAccountCredentialStore()
    let key = GitHubCredentialKey(
        connectionID: connection.id,
        accountID: expectedIdentity.id
    )
    try await store.save(
        GitHubCredential(accessToken: "ghu_access"),
        for: key
    )
    let baselineSaves = await store.saves()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport)
    )

    let result = try await coordinator.restore(
        connection: connection,
        identity: expectedIdentity
    )

    #expect(result.account.identity.id == "42")
    #expect(result.account.identity.login == "renamed-login")
    #expect(result.inventory.account.identity == result.account.identity)
    #expect(await store.saves() == baselineSaves)
}

private func restoredAccountConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func restoredAccountUserJSON(
    id: Int64,
    login: String
) -> String {
    """
    {"id":\(id),"login":"\(login)","name":null,"avatar_url":null}
    """
}
