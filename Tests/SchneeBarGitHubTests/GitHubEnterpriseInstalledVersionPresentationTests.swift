import Foundation
import SchneeBarGitHub
import Testing

private actor InstalledVersionPresentationTransport: GitHubHTTPTransport {
    private let data: Data

    init(json: String) {
        data = Data(json.utf8)
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

@Test(arguments: [
    #"{"installed_version":"3.22.0\u202Espoofed"}"#,
    #"{"installed_version":"3.22.0\u200Bspoofed"}"#,
    #"{"installed_version":"3.22.0\u2028spoofed"}"#,
    #"{"installed_version":"3.22.0\u2029spoofed"}"#,
])
func discoveryRejectsUnsafeUnicodeInstalledVersionPresentation(
    json: String
) async throws {
    let client = GitHubEnterpriseServerDiscoveryClient(
        transport: InstalledVersionPresentationTransport(json: json)
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
