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
func gheDraftRejectsInvalidTenantDNSLabelBeforeAuthentication() {
    let draft = GitHubConnectionDraft(
        deploymentKind: .gheDotCom,
        displayName: "Company GitHub",
        serverURL: "https://acme_team.ghe.com",
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


@Test
func draftRejectsUnsafeOrOversizedClientID() {
    let invalidClientIDs = [
        " Iv1.enterprise-client",
        "Iv1.\u{202E}enterprise-client",
        String(
            repeating: "a",
            count: GitHubClientIDPolicy.maximumCharacters + 1
        ),
    ]

    for clientID in invalidClientIDs {
        let draft = GitHubConnectionDraft(
            deploymentKind: .enterpriseServer,
            displayName: "Internal GitHub",
            serverURL: "https://github.internal.example",
            clientID: clientID
        )
        #expect(!draft.isReadyToConnect)
    }
}

@Test
func draftRejectsUnsafeOrOversizedDisplayName() {
    let unsafeDisplayNames = [
        " Internal GitHub",
        "Internal\u{202E}GitHub",
        "Internal\u{2028}GitHub",
        String(
            repeating: "a",
            count:
                GitHubConnectionDisplayNamePolicy.maximumCharacters + 1
        ),
    ]

    for displayName in unsafeDisplayNames {
        let draft = GitHubConnectionDraft(
            deploymentKind: .enterpriseServer,
            displayName: displayName,
            serverURL: "https://github.internal.example",
            clientID: "Iv1.enterprise-client"
        )
        #expect(!draft.isReadyToConnect)
    }
}

@Test
func generatedDeploymentDefaultsFollowSelectedDeployment() {
    var draft = GitHubConnectionDraft()

    draft.applyDeploymentDefaults(
        from: .githubDotCom,
        to: .gheDotCom
    )
    #expect(draft.deploymentKind == .gheDotCom)
    #expect(draft.displayName == "Company GitHub")
    #expect(draft.serverURL == "https://company.ghe.com")

    draft.applyDeploymentDefaults(
        from: .gheDotCom,
        to: .enterpriseServer
    )
    #expect(draft.deploymentKind == .enterpriseServer)
    #expect(draft.displayName == "Internal GitHub")
    #expect(draft.serverURL == "https://github.company.example")

    draft.applyDeploymentDefaults(
        from: .enterpriseServer,
        to: .githubDotCom
    )
    #expect(draft.deploymentKind == .githubDotCom)
    #expect(draft.displayName == "GitHub.com")
    #expect(draft.serverURL == "https://github.com")
}

@Test
func deploymentSwitchPreservesUserCustomizedValues() {
    var draft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Production Forge",
        serverURL: "https://git.internal.example:8443",
        clientID: "Iv1.enterprise-client"
    )

    draft.applyDeploymentDefaults(
        from: .enterpriseServer,
        to: .gheDotCom
    )

    #expect(draft.deploymentKind == .gheDotCom)
    #expect(draft.displayName == "Production Forge")
    #expect(draft.serverURL == "https://git.internal.example:8443")
    #expect(!draft.isReadyToConnect)
}
