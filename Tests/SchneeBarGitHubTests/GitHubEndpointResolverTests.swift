import Foundation
import SchneeBarGitHub
import Testing

@Test
func resolvesGitHubDotComEndpoints() throws {
    let endpoints = try GitHubEndpointResolver.resolve(
        deploymentKind: .githubDotCom,
        webBaseURL: #require(URL(string: "https://github.com/"))
    )

    #expect(endpoints.webBaseURL.absoluteString == "https://github.com")
    #expect(endpoints.restBaseURL.absoluteString == "https://api.github.com")
    #expect(endpoints.graphQLURL.absoluteString == "https://api.github.com/graphql")
    #expect(endpoints.authenticationBaseURL.absoluteString == "https://github.com")
}

@Test
func resolvesGHEDataResidencyEndpoints() throws {
    let endpoints = try GitHubEndpointResolver.resolve(
        deploymentKind: .gheDotCom,
        webBaseURL: #require(URL(string: "https://acme.ghe.com"))
    )

    #expect(endpoints.webBaseURL.absoluteString == "https://acme.ghe.com")
    #expect(endpoints.restBaseURL.absoluteString == "https://api.acme.ghe.com")
    #expect(endpoints.graphQLURL.absoluteString == "https://api.acme.ghe.com/graphql")
    #expect(endpoints.authenticationBaseURL.absoluteString == "https://acme.ghe.com")
}

@Test
func resolvesEnterpriseServerEndpoints() throws {
    let endpoints = try GitHubEndpointResolver.resolve(
        deploymentKind: .enterpriseServer,
        webBaseURL: #require(URL(string: "https://github.internal.example/"))
    )

    #expect(endpoints.webBaseURL.absoluteString == "https://github.internal.example")
    #expect(endpoints.restBaseURL.absoluteString == "https://github.internal.example/api/v3")
    #expect(endpoints.graphQLURL.absoluteString == "https://github.internal.example/api/graphql")
    #expect(endpoints.authenticationBaseURL.absoluteString == "https://github.internal.example")
}

@Test
func preservesExplicitEnterpriseServerHTTPSPort() throws {
    let endpoints = try GitHubEndpointResolver.resolve(
        deploymentKind: .enterpriseServer,
        webBaseURL: #require(URL(string: "https://github.internal.example:8443"))
    )

    #expect(endpoints.webBaseURL.absoluteString == "https://github.internal.example:8443")
    #expect(endpoints.restBaseURL.absoluteString == "https://github.internal.example:8443/api/v3")
    #expect(endpoints.graphQLURL.absoluteString == "https://github.internal.example:8443/api/graphql")
}

@Test(arguments: [
    "http://github.internal.example",
    "https://user:password@github.internal.example",
    "https://github.internal.example/custom/path",
    "https://github.internal.example?debug=true",
])
func rejectsUnsafeOrAmbiguousEnterpriseServerURLs(rawURL: String) throws {
    let url = try #require(URL(string: rawURL))
    #expect(throws: GitHubEndpointResolverError.self) {
        try GitHubEndpointResolver.resolve(
            deploymentKind: .enterpriseServer,
            webBaseURL: url
        )
    }
}

@Test(arguments: [
    (GitHubDeploymentKind.githubDotCom, "https://github.com:8443"),
    (GitHubDeploymentKind.gheDotCom, "https://acme.ghe.com:8443"),
])
func rejectsNonStandardPortsForHostedGitHub(
    deploymentKind: GitHubDeploymentKind,
    rawURL: String
) throws {
    let url = try #require(URL(string: rawURL))

    #expect(throws: GitHubEndpointResolverError.nonStandardPortNotAllowed) {
        try GitHubEndpointResolver.resolve(
            deploymentKind: deploymentKind,
            webBaseURL: url
        )
    }
}

@Test
func rejectsAPIHostAsGHEWebHost() throws {
    let url = try #require(URL(string: "https://api.acme.ghe.com"))

    #expect(throws: GitHubEndpointResolverError.invalidGHEHost) {
        try GitHubEndpointResolver.resolve(
            deploymentKind: .gheDotCom,
            webBaseURL: url
        )
    }
}

@Test(arguments: [
    "https://api.acme.ghe.com",
    "https://actions.acme.ghe.com",
    "https://raw.acme.ghe.com",
    "https://foo.bar.ghe.com",
])
func rejectsGHEServiceOrNestedHostsAsEnterpriseWebBase(
    rawURL: String
) throws {
    let url = try #require(URL(string: rawURL))

    #expect(throws: GitHubEndpointResolverError.invalidGHEHost) {
        try GitHubEndpointResolver.resolve(
            deploymentKind: .gheDotCom,
            webBaseURL: url
        )
    }
}

@Test
func rejectsSharedGHEAuthenticationHostAsEnterpriseWebBase() throws {
    let url = try #require(URL(string: "https://auth.ghe.com"))

    #expect(throws: GitHubEndpointResolverError.invalidGHEHost) {
        try GitHubEndpointResolver.resolve(
            deploymentKind: .gheDotCom,
            webBaseURL: url
        )
    }
}

@Test
func rejectsNonGitHubHostForGitHubDotComConnection() throws {
    let url = try #require(URL(string: "https://example.com"))

    #expect(throws: GitHubEndpointResolverError.invalidGitHubDotComHost) {
        try GitHubEndpointResolver.resolve(
            deploymentKind: .githubDotCom,
            webBaseURL: url
        )
    }
}
