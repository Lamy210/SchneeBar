import Foundation
import SchneeBarGitHub
import Testing

private struct WaiterStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor WaiterQueueTransport: GitHubHTTPTransport {
    private var responses: [WaiterStubResponse]
    private var requestCount = 0

    init(_ responses: [WaiterStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let response = responses.isEmpty
            ? WaiterStubResponse("{}", statusCode: 500)
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

    func requests() -> Int {
        requestCount
    }
}

private actor SleepRecorder {
    private var values: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        values.append(seconds)
    }

    func recorded() -> [TimeInterval] {
        values
    }
}

private let waiterNow = Date(timeIntervalSince1970: 20_000)

@Test
func waiterAccumulatesSlowDownAndNeverReturnsToShorterPendingInterval() async throws {
    let transport = WaiterQueueTransport([
        WaiterStubResponse(#"{"error":"authorization_pending"}"#),
        WaiterStubResponse(#"{"error":"slow_down"}"#),
        WaiterStubResponse(#"{"error":"slow_down"}"#),
        WaiterStubResponse(#"{"error":"authorization_pending"}"#),
        WaiterStubResponse(#"{"access_token":"ghu_access","token_type":"bearer"}"#),
    ])
    let sleeps = SleepRecorder()
    let client = GitHubDeviceFlowClient(transport: transport, now: { waiterNow })
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: client,
        sleeper: { seconds in await sleeps.record(seconds) }
    )

    let credential = try await waiter.waitForAuthorization(
        connection: try waiterConnection(),
        clientID: "Iv1.client",
        session: try waiterSession()
    )

    #expect(credential.accessToken == "ghu_access")
    #expect(await sleeps.recorded() == [5, 5, 10, 15, 15])
    #expect(await transport.requests() == 5)
}

@Test
func waiterUsesServerSlowDownIntervalWhenItIsLonger() async throws {
    let transport = WaiterQueueTransport([
        WaiterStubResponse(#"{"error":"slow_down","interval":30}"#),
        WaiterStubResponse(#"{"access_token":"ghu_access","token_type":"bearer"}"#),
    ])
    let sleeps = SleepRecorder()
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: GitHubDeviceFlowClient(transport: transport, now: { waiterNow }),
        sleeper: { seconds in await sleeps.record(seconds) }
    )

    _ = try await waiter.waitForAuthorization(
        connection: try waiterConnection(),
        clientID: "Iv1.client",
        session: try waiterSession()
    )

    #expect(await sleeps.recorded() == [5, 30])
}

@Test
func waiterMapsAccessDenied() async throws {
    let transport = WaiterQueueTransport([
        WaiterStubResponse(#"{"error":"access_denied"}"#)
    ])
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: GitHubDeviceFlowClient(transport: transport, now: { waiterNow }),
        sleeper: { _ in }
    )

    await #expect(throws: GitHubDeviceAuthorizationWaitError.accessDenied) {
        try await waiter.waitForAuthorization(
            connection: try waiterConnection(),
            clientID: "Iv1.client",
            session: try waiterSession()
        )
    }
}

@Test
func waiterMapsExpiredSession() async throws {
    let transport = WaiterQueueTransport([])
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: GitHubDeviceFlowClient(transport: transport, now: { waiterNow }),
        sleeper: { _ in }
    )
    let session = GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(URL(string: "https://github.com/login/device")),
        expiresAt: waiterNow,
        pollInterval: 5
    )

    await #expect(throws: GitHubDeviceAuthorizationWaitError.expired) {
        try await waiter.waitForAuthorization(
            connection: try waiterConnection(),
            clientID: "Iv1.client",
            session: session
        )
    }
}

@Test
func cancellationStopsBeforeNetworkPoll() async throws {
    let transport = WaiterQueueTransport([])
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: GitHubDeviceFlowClient(transport: transport, now: { waiterNow }),
        sleeper: { _ in throw CancellationError() }
    )

    await #expect(throws: CancellationError.self) {
        try await waiter.waitForAuthorization(
            connection: try waiterConnection(),
            clientID: "Iv1.client",
            session: try waiterSession()
        )
    }

    #expect(await transport.requests() == 0)
}

private func waiterConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func waiterSession() throws -> GitHubDeviceAuthorizationSession {
    GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(URL(string: "https://github.com/login/device")),
        expiresAt: waiterNow.addingTimeInterval(900),
        pollInterval: 5
    )
}
