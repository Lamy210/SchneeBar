@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor EnterpriseMetadataProfileStore: GitHubConnectionProfileStore {
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

private actor EnterpriseMetadataCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private let credential = GitHubCredential(
        accessToken: "enterprise-metadata-token"
    )

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

private actor EnterpriseMetadataSessionTransport: GitHubHTTPTransport {
    private var responses: [String]
    private let statusCode: Int
    private var apiVersions: [String?] = []

    init(
        refreshCount: Int,
        statusCode: Int = 200
    ) {
        responses = Array(
            repeating: enterpriseMetadataSessionResponses(),
            count: refreshCount
        ).flatMap { $0 }
        self.statusCode = statusCode
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        apiVersions.append(
            request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
        )
        let json = responses.removeFirst()
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

    func recordedAPIVersions() -> [String?] {
        apiVersions
    }
}

private actor EnterpriseMetadataDiscoveryTransport: GitHubHTTPTransport {
    private let json: String
    private let statusCode: Int
    private var calls = 0

    init(
        installedVersion: String = "3.22.0",
        statusCode: Int = 200
    ) {
        json = "{\"installed_version\":\"\(installedVersion)\"}"
        self.statusCode = statusCode
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        calls += 1
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

    func callCount() -> Int {
        calls
    }
}

private struct EnterpriseMetadataWorkflowLoader: GitHubWorkflowRunLoading {
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
func refreshRediscoveryUpdatesEnterpriseVersionBeforeSessionRestore() async throws {
    let now = Date(timeIntervalSince1970: 200_000)
    let profile = try enterpriseMetadataProfile(
        serverVersion: "3.20.8",
        lastCheckAt: now.addingTimeInterval(-(25 * 60 * 60))
    )
    let fixture = enterpriseMetadataFixture(
        profile: profile,
        now: now,
        refreshCount: 1
    )
    fixture.model.profiles = [profile]

    await fixture.model.refresh(profileID: profile.id)

    let updated = try #require(fixture.model.profiles.first)
    #expect(updated.connection.serverVersion == "3.22.0")
    #expect(updated.connection.apiVersion == "2026-03-10")
    #expect(updated.lastEnterpriseMetadataCheckAt == now)
    #expect(await fixture.discoveryTransport.callCount() == 1)

    let apiVersions = await fixture.sessionTransport.recordedAPIVersions()
    #expect(!apiVersions.isEmpty)
    #expect(apiVersions.allSatisfy { $0 == "2026-03-10" })
}

@Test @MainActor
func rediscoverySurfacesNewUntestedEnterpriseVersion() async throws {
    let now = Date(timeIntervalSince1970: 250_000)
    let profile = try enterpriseMetadataProfile(
        serverVersion: "3.22.0",
        lastCheckAt: now.addingTimeInterval(-(25 * 60 * 60))
    )
    let fixture = enterpriseMetadataFixture(
        profile: profile,
        now: now,
        refreshCount: 1,
        discoveredVersion: "3.23.0"
    )
    fixture.model.profiles = [profile]

    await fixture.model.refresh(profileID: profile.id)

    let updated = try #require(fixture.model.profiles.first)
    #expect(updated.connection.serverVersion == "3.23.0")
    #expect(
        fixture.model.statusByConnectionID[profile.id]
            == .untestedServer(version: "3.23.0")
    )
    #expect(await fixture.discoveryTransport.callCount() == 1)
}

@Test @MainActor
func failedEnterpriseRediscoveryDoesNotHideHealthySessionAndIsBounded() async throws {
    let now = Date(timeIntervalSince1970: 300_000)
    let profile = try enterpriseMetadataProfile(
        serverVersion: "3.20.8",
        lastCheckAt: nil
    )
    let fixture = enterpriseMetadataFixture(
        profile: profile,
        now: now,
        refreshCount: 2,
        discoveryStatusCode: 503
    )
    fixture.model.profiles = [profile]

    await fixture.model.refresh(profileID: profile.id)
    await fixture.model.refresh(profileID: profile.id)

    let updated = try #require(fixture.model.profiles.first)
    #expect(updated.connection.serverVersion == "3.20.8")
    #expect(updated.connection.apiVersion == "2022-11-28")
    #expect(updated.lastEnterpriseMetadataCheckAt == now)
    #expect(
        fixture.model.statusByConnectionID[profile.id]
            == .connected(repositoryCount: 1)
    )
    #expect(await fixture.discoveryTransport.callCount() == 1)
}

@Test @MainActor
func failedMetadataAndSessionStillBoundMetadataRetryCadence() async throws {
    let now = Date(timeIntervalSince1970: 350_000)
    let profile = try enterpriseMetadataProfile(
        serverVersion: "3.20.8",
        lastCheckAt: nil
    )
    let fixture = enterpriseMetadataFixture(
        profile: profile,
        now: now,
        refreshCount: 2,
        discoveryStatusCode: 503,
        sessionStatusCode: 503
    )
    fixture.model.profiles = [profile]

    await fixture.model.refresh(profileID: profile.id)
    await fixture.model.refresh(profileID: profile.id)

    let updated = try #require(fixture.model.profiles.first)
    #expect(updated.lastEnterpriseMetadataCheckAt == now)
    #expect(
        fixture.model.statusByConnectionID[profile.id]
            == .unavailable
    )
    #expect(await fixture.discoveryTransport.callCount() == 1)
}

@MainActor
private struct EnterpriseMetadataFixture {
    let model: GitHubConnectionsRuntimeModel
    let sessionTransport: EnterpriseMetadataSessionTransport
    let discoveryTransport: EnterpriseMetadataDiscoveryTransport
}

@MainActor
private func enterpriseMetadataFixture(
    profile: GitHubConnectionProfile,
    now: Date,
    refreshCount: Int,
    discoveredVersion: String = "3.22.0",
    discoveryStatusCode: Int = 200,
    sessionStatusCode: Int = 200
) -> EnterpriseMetadataFixture {
    let profileStore = EnterpriseMetadataProfileStore(profile: profile)
    let credentialStore = EnterpriseMetadataCredentialStore(profile: profile)
    let sessionTransport = EnterpriseMetadataSessionTransport(
        refreshCount: refreshCount,
        statusCode: sessionStatusCode
    )
    let discoveryTransport = EnterpriseMetadataDiscoveryTransport(
        installedVersion: discoveredVersion,
        statusCode: discoveryStatusCode
    )
    let sessionCoordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: sessionTransport)
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: sessionCoordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: EnterpriseMetadataWorkflowLoader()
        ),
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient(
            transport: discoveryTransport
        ),
        enterpriseMetadataRefreshPolicy: .init(
            minimumInterval: 24 * 60 * 60
        ),
        now: { now }
    )

    return EnterpriseMetadataFixture(
        model: model,
        sessionTransport: sessionTransport,
        discoveryTransport: discoveryTransport
    )
}

private func enterpriseMetadataProfile(
    serverVersion: String,
    lastCheckAt: Date?
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "68000000-0000-0000-0000-000000000001")!,
            displayName: "Internal GitHub",
            deploymentKind: .enterpriseServer,
            webBaseURL: try #require(
                URL(string: "https://github.internal.example")
            ),
            serverVersion: serverVersion
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "snow-user"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true,
        lastEnterpriseMetadataCheckAt: lastCheckAt
    )
}

private func enterpriseMetadataSessionResponses() -> [String] {
    [
        #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#,
        #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#,
        #"{"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{"actions":"read"},"suspended_at":null}]}"#,
        #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#,
    ]
}
