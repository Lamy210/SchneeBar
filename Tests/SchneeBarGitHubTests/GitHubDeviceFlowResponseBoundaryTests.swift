import Foundation
import SchneeBarGitHub
import Testing

private actor ResponseBoundaryTransport: GitHubHTTPTransport {
    private let responseJSON: String
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(responseJSON: String, statusCode: Int = 200) {
        self.responseJSON = responseJSON
        self.statusCode = statusCode
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(responseJSON.utf8), response)
    }

    func requestCount() -> Int {
        requests.count
    }
}

private let responseBoundaryNow = Date(timeIntervalSince1970: 1_000)

@Test
func oversizedDeviceFlowResponseFailsBeforeDecode() async throws {
    let payload = String(
        repeating: " ",
        count: GitHubDeviceFlowResponsePolicy.maximumResponseBytes + 1
    )
    let transport = ResponseBoundaryTransport(responseJSON: payload)
    let client = GitHubDeviceFlowClient(
        transport: transport,
        now: { responseBoundaryNow }
    )

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.begin(
            connection: try responseBoundaryConnection(),
            clientID: "Iv1.client"
        )
    }
    #expect(await transport.requestCount() == 1)
}

@Test
func oversizedAccessTokenFailsBeforeCredentialCreation() async throws {
    let token = String(
        repeating: "t",
        count: GitHubDeviceFlowResponsePolicy.maximumOpaqueTokenCharacters + 1
    )
    let payload =
        "{\"access_token\":\"\(token)\",\"token_type\":\"bearer\"}"

    try await expectPollInvalidResponse(payload)
}

@Test
func oversizedRefreshTokenFailsBeforeCredentialCreation() async throws {
    let token = String(
        repeating: "t",
        count: GitHubDeviceFlowResponsePolicy.maximumOpaqueTokenCharacters + 1
    )
    let payload =
        "{\"access_token\":\"ghu_access\","
        + "\"refresh_token\":\"\(token)\","
        + "\"token_type\":\"bearer\"}"

    try await expectPollInvalidResponse(payload)
}

@Test
func oversizedOrUnsafeOAuthErrorsFailClosed() async throws {
    let oversizedCode = String(
        repeating: "e",
        count: GitHubDeviceFlowResponsePolicy.maximumOAuthErrorCodeCharacters + 1
    )
    let oversizedDescription = String(
        repeating: "e",
        count:
            GitHubDeviceFlowResponsePolicy
                .maximumOAuthErrorDescriptionCharacters + 1
    )
    let unsafeCode = "custom\u{202E}error"

    try await expectBeginInvalidResponse(
        "{\"error\":\"\(oversizedCode)\"}"
    )
    try await expectBeginInvalidResponse(
        "{\"error\":\"custom_error\","
            + "\"error_description\":\"\(oversizedDescription)\"}"
    )
    try await expectBeginInvalidResponse(
        "{\"error\":\"\(unsafeCode)\"}"
    )
}

private func expectBeginInvalidResponse(
    _ payload: String
) async throws {
    let transport = ResponseBoundaryTransport(responseJSON: payload)
    let client = GitHubDeviceFlowClient(
        transport: transport,
        now: { responseBoundaryNow }
    )

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.begin(
            connection: try responseBoundaryConnection(),
            clientID: "Iv1.client"
        )
    }
    #expect(await transport.requestCount() == 1)
}

private func expectPollInvalidResponse(
    _ payload: String
) async throws {
    let transport = ResponseBoundaryTransport(responseJSON: payload)
    let client = GitHubDeviceFlowClient(
        transport: transport,
        now: { responseBoundaryNow }
    )

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.pollOnce(
            connection: try responseBoundaryConnection(),
            clientID: "Iv1.client",
            session: try responseBoundarySession()
        )
    }
    #expect(await transport.requestCount() == 1)
}

private func responseBoundarySession() throws -> GitHubDeviceAuthorizationSession {
    GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(
            URL(string: "https://github.com/login/device")
        ),
        expiresAt: responseBoundaryNow.addingTimeInterval(900),
        pollInterval: 5
    )
}

private func responseBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}
