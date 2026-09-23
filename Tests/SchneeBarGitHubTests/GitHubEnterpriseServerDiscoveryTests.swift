import Foundation
import SchneeBarGitHub
import Testing

private actor RecordingGitHubTransport: GitHubHTTPTransport {
    private let data: Data
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(json: String, statusCode: Int = 200) {
        data = Data(json.utf8)
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
        return (data, response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}

private struct FailingGitHubTransport: GitHubHTTPTransport {
    let error: URLError

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

@Test
func discoversSupportedEnterpriseServerVersionFromMetaEndpoint() async throws {
    let transport = RecordingGitHubTransport(
        json: #"{"installed_version":"3.22.0"}"#
    )
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    let result = try await client.discover(connection: connection)

    #expect(result.installedVersion == "3.22.0")
    #expect(result.parsedVersion == GitHubEnterpriseServerVersion(major: 3, minor: 22, patch: 0))
    #expect(result.compatibility == .tested)
    #expect(await transport.lastRequest()?.url?.absoluteString == "https://github.internal.example/api/v3/meta")
    #expect(await transport.lastRequest()?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(
        await transport.lastRequest()?
            .value(forHTTPHeaderField: "X-GitHub-Api-Version") == nil
    )
}

@Test
func discoveryPreservesEnterpriseServerCustomPort() async throws {
    let transport = RecordingGitHubTransport(
        json: #"{"installed_version":"3.21.4"}"#
    )
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Lab GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )

    _ = try await client.discover(connection: connection)

    #expect(await transport.lastRequest()?.url?.absoluteString == "https://github.internal.example:8443/api/v3/meta")
}

@Test(arguments: [
    ("3.19.9", GitHubEnterpriseCompatibility.olderUntested),
    ("3.20.0", GitHubEnterpriseCompatibility.tested),
    ("3.21.5", GitHubEnterpriseCompatibility.tested),
    ("3.22.1", GitHubEnterpriseCompatibility.tested),
    ("3.23.0", GitHubEnterpriseCompatibility.newerUntested),
    ("4.0.0", GitHubEnterpriseCompatibility.newerUntested),
    ("unknown", GitHubEnterpriseCompatibility.unknownVersion),
])
func classifiesEnterpriseServerVersions(
    rawVersion: String,
    expected: GitHubEnterpriseCompatibility
) {
    let parsed = GitHubEnterpriseServerVersion(parsing: rawVersion)
    let compatibility = GitHubEnterpriseCompatibilityPolicy().compatibility(for: parsed)
    #expect(compatibility == expected)
}

@Test
func parsesEnterpriseServerVersionSuffixWithoutRejectingDiscovery() {
    let version = GitHubEnterpriseServerVersion(parsing: "3.22.0-rc1")
    #expect(version == GitHubEnterpriseServerVersion(major: 3, minor: 22, patch: 0))
}

@Test
func rejectsDiscoveryForHostedGitHubConnection() async throws {
    let transport = RecordingGitHubTransport(
        json: #"{"installed_version":"3.22.0"}"#
    )
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )

    await #expect(throws: GitHubEnterpriseServerDiscoveryError.enterpriseServerConnectionRequired) {
        try await client.discover(connection: connection)
    }
}

@Test
func reportsNonSuccessHTTPStatus() async throws {
    let transport = RecordingGitHubTransport(json: "{}", statusCode: 503)
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    await #expect(throws: GitHubEnterpriseServerDiscoveryError.httpStatus(503)) {
        try await client.discover(connection: connection)
    }
}

@Test(arguments: [
    (URLError.Code.notConnectedToInternet, GitHubNetworkFailureKind.offline),
    (URLError.Code.cannotFindHost, GitHubNetworkFailureKind.hostResolution),
    (URLError.Code.cannotConnectToHost, GitHubNetworkFailureKind.connection),
    (URLError.Code.timedOut, GitHubNetworkFailureKind.timedOut),
    (URLError.Code.networkConnectionLost, GitHubNetworkFailureKind.connectionLost),
])
func reportsTypedNetworkFailureDuringEnterpriseDiscovery(
    code: URLError.Code,
    expected: GitHubNetworkFailureKind
) async throws {
    let client = GitHubEnterpriseServerDiscoveryClient(
        transport: FailingGitHubTransport(error: URLError(code))
    )
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    await #expect(
        throws: GitHubEnterpriseServerDiscoveryError.networkUnavailable(expected)
    ) {
        try await client.discover(connection: connection)
    }
}

@Test
func doesNotMaskEnterpriseDiscoveryTLSErrorsAsNetworkUnavailable() async throws {
    let client = GitHubEnterpriseServerDiscoveryClient(
        transport: FailingGitHubTransport(
            error: URLError(.serverCertificateUntrusted)
        )
    )
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    do {
        _ = try await client.discover(connection: connection)
        Issue.record("Expected the TLS failure to propagate")
    } catch let error as URLError {
        #expect(error.code == .serverCertificateUntrusted)
    } catch {
        Issue.record("Expected URLError, received \(error)")
    }
}

@Test
func normalizesReportedEnterpriseVersionBeforeUse() async throws {
    let transport = RecordingGitHubTransport(
        json: #"{"installed_version":"  3.22.0-rc1  \n"}"#
    )
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    let result = try await client.discover(connection: connection)

    #expect(result.installedVersion == "3.22.0-rc1")
    #expect(
        result.parsedVersion
            == GitHubEnterpriseServerVersion(major: 3, minor: 22, patch: 0)
    )
}

@Test
func rejectsEmptyEnterpriseVersionMetadata() async throws {
    let transport = RecordingGitHubTransport(
        json: #"{"installed_version":"   \n  "}"#
    )
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    await #expect(throws: GitHubEnterpriseServerDiscoveryError.invalidPayload) {
        try await client.discover(connection: connection)
    }
}

@Test
func reportsInvalidMetaPayload() async throws {
    let transport = RecordingGitHubTransport(json: #"{"ver":"3.22.0"}"#)
    let client = GitHubEnterpriseServerDiscoveryClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    await #expect(throws: GitHubEnterpriseServerDiscoveryError.invalidPayload) {
        try await client.discover(connection: connection)
    }
}


@Test
func enterpriseMetadataRefreshPolicyOnlyChecksEnterpriseServersWhenDue() throws {
    let policy = GitHubEnterpriseMetadataRefreshPolicy(
        minimumInterval: 60 * 60
    )
    let now = Date(timeIntervalSince1970: 100_000)
    let enterprise = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example")
        ),
        serverVersion: "3.22.0"
    )
    let hosted = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )

    #expect(
        policy.shouldRefresh(
            connection: enterprise,
            lastCheckedAt: nil,
            now: now
        )
    )
    #expect(
        !policy.shouldRefresh(
            connection: enterprise,
            lastCheckedAt: now.addingTimeInterval(-(60 * 60) + 1),
            now: now
        )
    )
    #expect(
        policy.shouldRefresh(
            connection: enterprise,
            lastCheckedAt: now.addingTimeInterval(-(60 * 60)),
            now: now
        )
    )
    #expect(
        policy.shouldRefresh(
            connection: enterprise,
            lastCheckedAt: now.addingTimeInterval(60),
            now: now
        )
    )
    #expect(
        !policy.shouldRefresh(
            connection: hosted,
            lastCheckedAt: nil,
            now: now
        )
    )
}
