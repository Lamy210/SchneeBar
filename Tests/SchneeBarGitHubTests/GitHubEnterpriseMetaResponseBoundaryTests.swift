import Foundation
import SchneeBarGitHub
import Testing

private actor EnterpriseMetaResponseBoundaryTransport: GitHubHTTPTransport {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (data, response)
    }
}

@Test
func discoveryRejectsOversizedMetaResponseBeforeDecode() async throws {
    let oversizedPadding = String(
        repeating: "x",
        count: 1024 * 1024
    )
    let payload = Data(
        (
            "{\"installed_version\":\"3.22.0\","
                + "\"padding\":\"\(oversizedPadding)\"}"
        ).utf8
    )
    let client = GitHubEnterpriseServerDiscoveryClient(
        transport: EnterpriseMetaResponseBoundaryTransport(data: payload)
    )
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example")
        )
    )

    await #expect(
        throws: GitHubEnterpriseServerDiscoveryError.invalidPayload
    ) {
        try await client.discover(connection: connection)
    }
}
