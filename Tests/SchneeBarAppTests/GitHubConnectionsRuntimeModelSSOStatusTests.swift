@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private struct SSOStatusResponse: Sendable {
    let json: String
    let statusCode: Int
    let headers: [String: String]

    init(
        _ json: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) {
        self.json = json
        self.statusCode = statusCode
        self.headers = headers
    }
}

private actor SSOStatusTransport: GitHubHTTPTransport {
    private var responses: [SSOStatusResponse]

    init(_ responses: [SSOStatusResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let stub = responses.removeFirst()
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        )
        return (Data(stub.json.utf8), response)
    }
}

private actor SSOStatusProfileStore: GitHubConnectionProfileStore {
    private var profile: GitHubConnectionProfile

    init(profile: GitHubConnectionProfile) {
        self.profile = profile
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { [profile] }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        profile.id == id ? profile : nil
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        self.profile = profile
    }

    func delete(id: UUID) async throws {}
}

private actor SSOStatusCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private let credential = GitHubCredential(accessToken: "sso-status-token")

    init(profile: GitHubConnectionProfile) {
        key = GitHubCredentialKey(
            connectionID: profile.id,
            accountID: profile.account.id
        )
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        key == self.key ? credential : nil
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {}

    func delete(for key: GitHubCredentialKey) async throws {}
}

private struct SSOStatusWorkflowLoader: GitHubWorkflowRunLoading {
    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        []
    }
}

@Test @MainActor
func refreshSurfacesSSORequiredOnlyFromExplicitFailureEvidence() async throws {
    let profile = try ssoStatusProfile()
    let model = ssoStatusModel(
        profile: profile,
        responses: ssoOnlyResponses(
            repositoryHeaders: [
                "X-GitHub-SSO":
                    "required; url=https://github.com/orgs/acme/sso?authorization_request=sensitive"
            ]
        )
    )
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    #expect(model.connectionCards.first?.status == .ssoRequired)
}

@Test @MainActor
func topLevelInventorySSOFailureSurfacesSSORequired() async throws {
    let profile = try ssoStatusProfile()
    let model = ssoStatusModel(
        profile: profile,
        responses: [
            SSOStatusResponse(
                #"{"id":42,"login":"snow-user","name":null,"avatar_url":null}"#
            ),
            SSOStatusResponse(
                #"{"id":42,"login":"snow-user","name":null,"avatar_url":null}"#
            ),
            SSOStatusResponse(
                #"{"message":"SSO required"}"#,
                statusCode: 403,
                headers: [
                    "X-GitHub-SSO":
                        "required; url=https://github.com/orgs/acme/sso?authorization_request=sensitive"
                ]
            ),
        ]
    )
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    #expect(model.connectionCards.first?.status == .ssoRequired)
}

@Test @MainActor
func ordinaryRepository403RemainsUnavailable() async throws {
    let profile = try ssoStatusProfile()
    let model = ssoStatusModel(
        profile: profile,
        responses: ssoOnlyResponses(repositoryHeaders: [:])
    )
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    #expect(model.connectionCards.first?.status == .unavailable)
}

@Test @MainActor
func availableInstallationKeepsConnectionConnectedWhenAnotherNeedsSSO() async throws {
    let profile = try ssoStatusProfile()
    let model = ssoStatusModel(
        profile: profile,
        responses: mixedAccessResponses()
    )
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    #expect(
        model.connectionCards.first?.status
            == .connectedWithSSORequired(
                repositoryCount: 1,
                affectedInstallationCount: 1
            )
    )
}

@Test @MainActor
func availableInstallationWithOrdinary403RemainsConnected() async throws {
    let profile = try ssoStatusProfile()
    let model = ssoStatusModel(
        profile: profile,
        responses: mixedAccessResponses(repositoryHeaders: [:])
    )
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    #expect(
        model.connectionCards.first?.status
            == .connected(repositoryCount: 1)
    )
}

@MainActor
private func ssoStatusModel(
    profile: GitHubConnectionProfile,
    responses: [SSOStatusResponse]
) -> GitHubConnectionsRuntimeModel {
    let transport = SSOStatusTransport(responses)
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: SSOStatusCredentialStore(profile: profile),
        accessClient: GitHubAccessClient(transport: transport)
    )

    return GitHubConnectionsRuntimeModel(
        profileStore: SSOStatusProfileStore(profile: profile),
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: SSOStatusWorkflowLoader()
        )
    )
}

private func ssoStatusProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "69000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "snow-user"),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id"
    )
}

private func ssoOnlyResponses(
    repositoryHeaders: [String: String]
) -> [SSOStatusResponse] {
    [
        SSOStatusResponse(#"{"id":42,"login":"snow-user","name":null,"avatar_url":null}"#),
        SSOStatusResponse(#"{"id":42,"login":"snow-user","name":null,"avatar_url":null}"#),
        SSOStatusResponse(
            #"{"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"acme","type":"Organization","avatar_url":null},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}]}"#
        ),
        SSOStatusResponse(
            #"{"message":"Forbidden"}"#,
            statusCode: 403,
            headers: repositoryHeaders
        ),
    ]
}

private func mixedAccessResponses(
    repositoryHeaders: [String: String] = [
        "X-GitHub-SSO":
            "required; url=https://github.com/orgs/protected/sso?authorization_request=sensitive"
    ]
) -> [SSOStatusResponse] {
    [
        SSOStatusResponse(#"{"id":42,"login":"snow-user","name":null,"avatar_url":null}"#),
        SSOStatusResponse(#"{"id":42,"login":"snow-user","name":null,"avatar_url":null}"#),
        SSOStatusResponse(
            #"{"total_count":2,"installations":[{"id":10,"account":{"id":100,"login":"visible","type":"Organization","avatar_url":null},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null},{"id":20,"account":{"id":200,"login":"protected","type":"Organization","avatar_url":null},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}]}"#
        ),
        SSOStatusResponse(
            #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"visible/app","private":true,"owner":{"id":100,"login":"visible","type":"Organization","avatar_url":null},"permissions":{"pull":true}}]}"#
        ),
        SSOStatusResponse(
            #"{"message":"Forbidden"}"#,
            statusCode: 403,
            headers: repositoryHeaders
        ),
    ]
}
