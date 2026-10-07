import Foundation
import SchneeBarGitHub
import Testing

private actor FreshAccountCredentialStore: GitHubCredentialStore {
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

private struct FreshAccountStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor FreshAccountTransport: GitHubHTTPTransport {
    private var responses: [FreshAccountStubResponse]

    init(_ responses: [FreshAccountStubResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? FreshAccountStubResponse("{}", statusCode: 500)
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
func establishUsesFreshInventoryAccountMetadataWhenStableIDMatches() async throws {
    let transport = FreshAccountTransport([
        FreshAccountStubResponse(freshAccountUserJSON(id: 42, login: "old-login")),
        FreshAccountStubResponse(freshAccountUserJSON(id: 42, login: "renamed-login")),
        FreshAccountStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = FreshAccountCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport)
    )

    let result = try await coordinator.establish(
        connection: try freshAccountConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(result.account.identity.id == "42")
    #expect(result.account.identity.login == "renamed-login")
    #expect(result.inventory.account.identity == result.account.identity)
    #expect(await store.saves() == 1)
}

private func freshAccountConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func freshAccountUserJSON(
    id: Int64,
    login: String
) -> String {
    """
    {"id":\(id),"login":"\(login)","name":null,"avatar_url":null}
    """
}
