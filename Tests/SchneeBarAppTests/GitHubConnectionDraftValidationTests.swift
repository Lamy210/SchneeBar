import Foundation
import SchneeBarGitHub
import SchneeBarGitHubFeature
import Testing

@Test
func githubDotComDraftUsesCanonicalHostedEndpoint() throws {
    let draft = GitHubConnectionDraft(
        deploymentKind: .githubDotCom,
        displayName: "GitHub.com",
        serverURL: "https://ignored.example",
        clientID: "Iv1.public-client"
    )

    #expect(draft.isReadyToConnect)
    #expect(draft.endpointValidationError == nil)
    #expect(
        try draft.resolvedWebBaseURL().absoluteString
            == "https://github.com"
    )
}

@Test
func gheDraftCanonicalizesHostAndDefaultPort() throws {
    let draft = GitHubConnectionDraft(
        deploymentKind: .gheDotCom,
        displayName: "Company GitHub",
        serverURL: "https://ACME.GHE.COM:443/",
        clientID: "Iv1.enterprise-client"
    )

    #expect(draft.isReadyToConnect)
    #expect(
        try draft.resolvedWebBaseURL().absoluteString
            == "https://acme.ghe.com"
    )
}

@Test
func gheDraftRejectsAPIHostBeforeAuthentication() {
    let draft = GitHubConnectionDraft(
        deploymentKind: .gheDotCom,
        displayName: "Company GitHub",
        serverURL: "https://api.acme.ghe.com",
        clientID: "Iv1.enterprise-client"
    )

    #expect(!draft.isReadyToConnect)
    #expect(
        draft.endpointValidationError
            == .unsupportedEndpoint(.invalidGHEHost)
    )
}

@Test
func hostedDraftRejectsPathBeforeAuthentication() {
    let draft = GitHubConnectionDraft(
        deploymentKind: .gheDotCom,
        displayName: "Company GitHub",
        serverURL: "https://acme.ghe.com/enterprise",
        clientID: "Iv1.enterprise-client"
    )

    #expect(!draft.isReadyToConnect)
    #expect(
        draft.endpointValidationError
            == .unsupportedEndpoint(.pathNotAllowed)
    )
}

@Test
func enterpriseServerDraftPreservesExplicitHTTPSPort() throws {
    let draft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Internal GitHub",
        serverURL: "https://GITHUB.INTERNAL.EXAMPLE:8443/",
        clientID: "Iv1.enterprise-client"
    )

    #expect(draft.isReadyToConnect)
    #expect(
        try draft.resolvedWebBaseURL().absoluteString
            == "https://github.internal.example:8443"
    )
}

@Test
func enterpriseDraftRequiresServerURL() {
    let draft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Internal GitHub",
        serverURL: "   ",
        clientID: "Iv1.enterprise-client"
    )

    #expect(!draft.isReadyToConnect)
    #expect(draft.endpointValidationError == .serverURLRequired)
}

@Test
func draftStillRequiresDisplayNameAndClientID() {
    let draft = GitHubConnectionDraft(
        deploymentKind: .gheDotCom,
        displayName: " ",
        serverURL: "https://acme.ghe.com",
        clientID: ""
    )

    #expect(!draft.isReadyToConnect)
    #expect(draft.endpointValidationError == nil)
}
