import Foundation
import SchneeBarGitHub
import Testing

@Test
func credentialDecodesLegacyPayloadWithoutEndpointBinding() throws {
    let data = Data(
        #"""
        {
          "accessToken": "legacy-token",
          "refreshToken": null,
          "accessTokenExpiresAt": null,
          "refreshTokenExpiresAt": null
        }
        """#.utf8
    )

    let credential = try JSONDecoder().decode(
        GitHubCredential.self,
        from: data
    )

    #expect(credential.accessToken == "legacy-token")
    #expect(credential.endpointIdentity == nil)
}

@Test
func credentialCodingPreservesEndpointBinding() throws {
    let expected = GitHubCredential(
        accessToken: "bound-token",
        refreshToken: "refresh-token",
        endpointIdentity: "https://github.internal.example"
    )

    let encoded = try JSONEncoder().encode(expected)
    let decoded = try JSONDecoder().decode(
        GitHubCredential.self,
        from: encoded
    )

    #expect(decoded == expected)
    #expect(
        decoded.endpointIdentity
            == "https://github.internal.example"
    )
}
