import Foundation
import SchneeBarGitHub
import Testing

private actor RecoveredAccountCredentialStore: GitHubCredentialStore {
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

private struct RecoveredAccountStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor RecoveredAccountTransport: GitHubHTTPTransport {
    private var responses: [RecoveredAccountStubResponse]

    init(_ responses: [RecoveredAccountStubResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? RecoveredAccountStubResponse("{}", statusCode: 500)
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
func recoverUsesFreshInventoryAccountMetadataWhenStableIDMatches() async throws {
    let connection = try recoveredAccountConnection()
    let expectedIdentity = GitHubAccountIdentity(
        id: "42",
        login: "old-login"
    )
    let transport = RecoveredAccountTransport([
        RecoveredAccountStubResponse(recoveredAccountUserJSON(id: 42, login: "old-login")),
        RecoveredAccountStubResponse(recoveredAccountUserJSON(id: 42, login: "renamed-login")),
        RecoveredAccountStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = RecoveredAccountCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport)
    )

    let result = try await coordinator.recover(
        connection: connection,
        expectedIdentity: expectedIdentity,
        credential: GitHubCredential(accessToken: "ghu_recovered")
    )

    #expect(result.account.identity.id == "42")
    #expect(result.account.identity.login == "renamed-login")
    #expect(result.inventory.account.identity == result.account.identity)
    #expect(await store.saves() == 1)
}

private func recoveredAccountConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func recoveredAccountUserJSON(
    id: Int64,
    login: String
) -> String {
    """
    {"id":\(id),"login":"\(login)","name":null,"avatar_url":null}
    """
}
