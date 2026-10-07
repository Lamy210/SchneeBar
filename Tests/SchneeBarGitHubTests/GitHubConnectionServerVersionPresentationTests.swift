import Foundation
import SchneeBarGitHub
import Testing

@Test
func decodedEnterpriseConnectionSanitizesUnsafePersistedServerVersion() throws {
    let data = Data(
        #"{"id":"42000000-0000-0000-0000-000000000001","displayName":"Internal GitHub","deploymentKind":"enterpriseServer","webBaseURL":"https://github.internal.example","serverVersion":"3.23.0\u202Espoof","apiVersion":"custom-version"}"#.utf8
    )

    let connection = try JSONDecoder().decode(
        GitHubConnection.self,
        from: data
    )

    #expect(
        connection.serverVersion
            == GitHubEnterpriseServerVersionPresentationPolicy.unknownVersion
    )
    #expect(connection.apiVersion == "custom-version")

    let roundTrip = try JSONDecoder().decode(
        GitHubConnection.self,
        from: JSONEncoder().encode(connection)
    )
    #expect(
        roundTrip.serverVersion
            == GitHubEnterpriseServerVersionPresentationPolicy.unknownVersion
    )
    #expect(roundTrip.apiVersion == "custom-version")
}

@Test
func safeEnterpriseConnectionVersionStillDerivesAPICompatibility() throws {
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example")
        ),
        serverVersion: " 3.22.0 "
    )

    #expect(connection.serverVersion == "3.22.0")
    #expect(connection.apiVersion == GitHubRESTAPIVersionPolicy.currentVersion)
}
