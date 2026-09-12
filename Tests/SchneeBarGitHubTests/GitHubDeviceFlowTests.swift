import Foundation
import SchneeBarGitHub
import Testing

private struct DeviceFlowStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor QueueGitHubTransport: GitHubHTTPTransport {
    private var responses: [DeviceFlowStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [DeviceFlowStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? DeviceFlowStubResponse("{}", statusCode: 500)
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

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_000)

@Test
func beginsDeviceFlowWithoutClientSecret() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(
            #"{"device_code":"device-123","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        )
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })

    let session = try await client.begin(
        connection: try githubDotComConnection(),
        clientID: "Iv1.public-client-id"
    )

    #expect(session.deviceCode == "device-123")
    #expect(session.userCode == "ABCD-EFGH")
    #expect(session.verificationURI.absoluteString == "https://github.com/login/device")
    #expect(session.pollInterval == 5)
    #expect(session.expiresAt == fixedNow.addingTimeInterval(900))

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.url?.absoluteString == "https://github.com/login/device/code")
    let body = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
    #expect(body.contains("client_id=Iv1.public-client-id"))
    #expect(!body.contains("client_secret"))
}

@Test
func beginsDeviceFlowAgainstCustomPortGHES() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(
            #"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.internal.example:8443/login/device","expires_in":900,"interval":5}"#
        )
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )

    _ = try await client.begin(connection: connection, clientID: "Iv1.enterprise")

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.url?.absoluteString == "https://github.internal.example:8443/login/device/code")
}

@Test
func mapsDeviceFlowDisabledErrorDuringBegin() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(#"{"error":"device_flow_disabled","error_description":"Enable Device Flow"}"#)
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })

    await #expect(throws: GitHubDeviceFlowError.deviceFlowDisabled) {
        try await client.begin(
            connection: try githubDotComConnection(),
            clientID: "Iv1.client"
        )
    }
}

@Test
func rejectsVerificationURIFromDifferentOrigin() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(
            #"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://example.com/login/device","expires_in":900,"interval":5}"#
        )
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })

    await #expect(throws: GitHubDeviceFlowError.untrustedVerificationURI) {
        try await client.begin(
            connection: try githubDotComConnection(),
            clientID: "Iv1.client"
        )
    }
}

@Test
func mapsPendingAndSlowDownPollStates() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(#"{"error":"authorization_pending"}"#),
        DeviceFlowStubResponse(#"{"error":"slow_down","interval":10}"#),
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })
    let session = GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(URL(string: "https://github.com/login/device")),
        expiresAt: fixedNow.addingTimeInterval(900),
        pollInterval: 5
    )
    let connection = try githubDotComConnection()

    let pending = try await client.pollOnce(
        connection: connection,
        clientID: "Iv1.client",
        session: session
    )
    #expect(pending == .pending(retryAfter: 5))

    let slowed = try await client.pollOnce(
        connection: connection,
        clientID: "Iv1.client",
        session: session
    )
    #expect(slowed == .slowDown(retryAfter: 10))
}

@Test
func returnsRotatableCredentialAfterAuthorization() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(
            #"{"access_token":"ghu_access","expires_in":28800,"refresh_token":"ghr_refresh","refresh_token_expires_in":15897600,"token_type":"bearer","scope":""}"#
        )
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })
    let session = GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(URL(string: "https://github.com/login/device")),
        expiresAt: fixedNow.addingTimeInterval(900),
        pollInterval: 5
    )

    let result = try await client.pollOnce(
        connection: try githubDotComConnection(),
        clientID: "Iv1.client",
        session: session
    )

    let credential: GitHubCredential
    switch result {
    case let .authorized(value):
        credential = value
    default:
        Issue.record("Expected an authorized credential")
        return
    }

    #expect(credential.accessToken == "ghu_access")
    #expect(credential.refreshToken == "ghr_refresh")
    #expect(credential.accessTokenExpiresAt == fixedNow.addingTimeInterval(28_800))
    #expect(credential.refreshTokenExpiresAt == fixedNow.addingTimeInterval(15_897_600))
}

@Test
func refreshesDeviceFlowCredentialWithoutClientSecret() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(
            #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer","scope":""}"#
        )
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })
    let old = GitHubCredential(
        accessToken: "ghu_old",
        refreshToken: "ghr_old"
    )

    let refreshed = try await client.refresh(
        connection: try githubDotComConnection(),
        clientID: "Iv1.client",
        credential: old
    )

    #expect(refreshed.accessToken == "ghu_new")
    #expect(refreshed.refreshToken == "ghr_new")

    let request = try #require(await transport.recordedRequests().last)
    let body = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
    #expect(body.contains("client_id=Iv1.client"))
    #expect(body.contains("grant_type=refresh_token"))
    #expect(body.contains("refresh_token=ghr_old"))
    #expect(!body.contains("client_secret"))
}

@Test
func expiredSessionStopsBeforeNetworkPoll() async throws {
    let transport = QueueGitHubTransport([])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })
    let session = GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(URL(string: "https://github.com/login/device")),
        expiresAt: fixedNow,
        pollInterval: 5
    )

    let result = try await client.pollOnce(
        connection: try githubDotComConnection(),
        clientID: "Iv1.client",
        session: session
    )

    #expect(result == .expired)
    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func mapsDeviceFlowDisabledErrorDuringPoll() async throws {
    let transport = QueueGitHubTransport([
        DeviceFlowStubResponse(#"{"error":"device_flow_disabled"}"#)
    ])
    let client = GitHubDeviceFlowClient(transport: transport, now: { fixedNow })
    let session = GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(URL(string: "https://github.com/login/device")),
        expiresAt: fixedNow.addingTimeInterval(900),
        pollInterval: 5
    )

    await #expect(throws: GitHubDeviceFlowError.deviceFlowDisabled) {
        try await client.pollOnce(
            connection: try githubDotComConnection(),
            clientID: "Iv1.client",
            session: session
        )
    }
}

private func githubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}
