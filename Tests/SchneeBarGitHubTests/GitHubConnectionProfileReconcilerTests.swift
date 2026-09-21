import Foundation
import SchneeBarGitHub
import Testing

private let lifecycleNow = Date(timeIntervalSince1970: 20_000)

@Test
func profileReconcilerReusesSameEndpointAndAccountWhilePreservingUserSettings() throws {
    let existingConnectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    let incomingConnectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
    let createdAt = Date(timeIntervalSince1970: 1_000)

    let existing = GitHubConnectionProfile(
        connection: GitHubConnection(
            id: existingConnectionID,
            displayName: "Old GitHub",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "old-login"),
        authenticationMethod: .deviceFlow,
        clientID: "old-client",
        repositorySelection: .selected([101, 102]),
        isEnabled: false,
        createdAt: createdAt,
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
    let incoming = GitHubConnection(
        id: incomingConnectionID,
        displayName: "Work GitHub",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://GITHUB.COM/"))
    )

    let profile = GitHubConnectionProfileReconciler().reconcile(
        existingProfiles: [existing],
        authenticatedConnection: incoming,
        account: GitHubAccountIdentity(id: "42", login: "renamed-login"),
        authenticationMethod: .deviceFlow,
        clientID: "new-client",
        now: lifecycleNow
    )

    #expect(profile.id == existingConnectionID)
    #expect(profile.connection.displayName == "Work GitHub")
    #expect(profile.account == GitHubAccountIdentity(id: "42", login: "renamed-login"))
    #expect(profile.clientID == "new-client")
    #expect(profile.repositorySelection == .selected([101, 102]))
    #expect(profile.isEnabled == false)
    #expect(profile.createdAt == createdAt)
    #expect(profile.lastConnectedAt == lifecycleNow)
}

@Test
func profileReconcilerAllowsDifferentAccountsOnSameEndpoint() throws {
    let existing = makeLifecycleProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
        accountID: "42",
        login: "octocat"
    )
    let incomingID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
    let incoming = GitHubConnection(
        id: incomingID,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )

    let profile = GitHubConnectionProfileReconciler().reconcile(
        existingProfiles: [existing],
        authenticatedConnection: incoming,
        account: GitHubAccountIdentity(id: "99", login: "hubot"),
        authenticationMethod: .deviceFlow,
        clientID: "client",
        now: lifecycleNow
    )

    #expect(profile.id == incomingID)
    #expect(profile.account.id == "99")
    #expect(profile.repositorySelection == .allAccessible)
    #expect(profile.isEnabled)
    #expect(profile.createdAt == lifecycleNow)
    #expect(profile.lastConnectedAt == lifecycleNow)
}

@Test
func profileReconcilerDoesNotReuseSameAccountAcrossDifferentEnterpriseHosts() throws {
    let existing = GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            displayName: "Enterprise A",
            deploymentKind: .enterpriseServer,
            webBaseURL: try #require(URL(string: "https://github-a.example.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "octocat"),
        authenticationMethod: .deviceFlow
    )
    let incomingID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
    let incoming = GitHubConnection(
        id: incomingID,
        displayName: "Enterprise B",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github-b.example.com"))
    )

    let profile = GitHubConnectionProfileReconciler().reconcile(
        existingProfiles: [existing],
        authenticatedConnection: incoming,
        account: GitHubAccountIdentity(id: "42", login: "octocat"),
        authenticationMethod: .deviceFlow,
        clientID: "client",
        now: lifecycleNow
    )

    #expect(profile.id == incomingID)
}

@Test
func profileOrderingIsDeterministicAcrossInputOrder() throws {
    let alphaA = makeLifecycleProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayName: "Alpha",
        accountID: "2",
        login: "beta"
    )
    let alphaB = makeLifecycleProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        displayName: "alpha",
        accountID: "1",
        login: "alpha"
    )
    let zeta = makeLifecycleProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        displayName: "Zeta",
        accountID: "3",
        login: "zeta"
    )

    let first = GitHubConnectionProfileOrdering.sorted([zeta, alphaA, alphaB])
    let second = GitHubConnectionProfileOrdering.sorted([alphaB, zeta, alphaA])

    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.map(\.id) == [alphaB.id, alphaA.id, zeta.id])
}

private func makeLifecycleProfile(
    id: UUID,
    displayName: String = "GitHub.com",
    accountID: String,
    login: String
) -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: displayName,
            deploymentKind: .githubDotCom,
            webBaseURL: URL(string: "https://github.com")!
        ),
        account: GitHubAccountIdentity(id: accountID, login: login),
        authenticationMethod: .deviceFlow
    )
}


@Test
func profileReconcilerRecordsEnterpriseMetadataCheckTime() throws {
    let incoming = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example")
        ),
        serverVersion: "3.22.0"
    )

    let profile = GitHubConnectionProfileReconciler().reconcile(
        existingProfiles: [],
        authenticatedConnection: incoming,
        account: GitHubAccountIdentity(id: "42", login: "octocat"),
        authenticationMethod: .deviceFlow,
        clientID: "client",
        now: lifecycleNow
    )

    #expect(profile.lastEnterpriseMetadataCheckAt == lifecycleNow)
}
