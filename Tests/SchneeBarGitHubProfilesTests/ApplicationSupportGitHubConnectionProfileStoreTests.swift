import Darwin
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func missingProfileFileLoadsAsEmptyCollection() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let profiles = try await context.store.loadAll()

    #expect(profiles.isEmpty)
}

@Test
func profileStoreRoundTripsNonSecretConnectionMetadata() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }
    let expected = try makeProfile()

    try await context.store.save(expected)

    #expect(try await context.store.load(id: expected.id) == expected)
    #expect(try await context.store.loadAll() == [expected])

    let raw = try String(contentsOf: context.fileURL, encoding: .utf8)
    #expect(raw.contains("github.com"))
    #expect(raw.contains("Iv1.public-client"))
    #expect(!raw.contains("lastEnterpriseMetadataCheckAt"))
    #expect(!raw.contains("access_token"))
    #expect(!raw.contains("refresh_token"))
}

@Test
func profileStoreRoundTripsEnterpriseMetadataCheckTime() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }
    var expected = try makeProfile()
    let checkTime = Date(timeIntervalSince1970: 1_750)
    expected.lastEnterpriseMetadataCheckAt = checkTime

    try await context.store.save(expected)

    let loaded = try #require(await context.store.load(id: expected.id))
    #expect(loaded.lastEnterpriseMetadataCheckAt == checkTime)

    let raw = try String(contentsOf: context.fileURL, encoding: .utf8)
    #expect(raw.contains("lastEnterpriseMetadataCheckAt"))
}

@Test
func savingSameConnectionReplacesProfileInsteadOfDuplicatingIt() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }
    var profile = try makeProfile()
    try await context.store.save(profile)

    profile.isEnabled = false
    profile.repositorySelection = .selected([101, 202])
    profile.lastConnectedAt = Date(timeIntervalSince1970: 2_000)
    try await context.store.save(profile)

    let profiles = try await context.store.loadAll()
    #expect(profiles.count == 1)
    #expect(profiles[0] == profile)
}

@Test
func savingDifferentConnectionForSameEndpointAndAccountIsRejected() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }
    let existing = try makeProfile()
    var duplicate = try makeProfile(
        connectionID: UUID(
            uuidString: "10000000-0000-0000-0000-000000000099"
        )!
    )
    duplicate.connection.displayName = "Duplicate GitHub"
    duplicate.account.login = "renamed-login"
    duplicate.createdAt = existing.createdAt.addingTimeInterval(100)

    try await context.store.save(existing)

    await #expect(throws: GitHubConnectionProfileStoreError.self) {
        try await context.store.save(duplicate)
    }

    #expect(try await context.store.loadAll() == [existing])
}

@Test
func deletingProfileIsIdempotent() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }
    let profile = try makeProfile()
    try await context.store.save(profile)

    try await context.store.delete(id: profile.id)
    try await context.store.delete(id: profile.id)

    #expect(try await context.store.loadAll().isEmpty)
}

@Test
func unsupportedSchemaVersionIsRejectedWithoutOverwritingFile() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }
    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let raw = #"{"profiles":[],"schemaVersion":999}"#
    try Data(raw.utf8).write(to: context.fileURL)

    await #expect(
        throws: GitHubConnectionProfileStoreError.unsupportedSchemaVersion(999)
    ) {
        try await context.store.loadAll()
    }

    #expect(try String(contentsOf: context.fileURL, encoding: .utf8) == raw)
}

@Test
func profileStoreRejectsSymlinkBackingFile() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let target = context.directory.appendingPathComponent(
        "target.json",
        isDirectory: false
    )
    try Data(#"{"profiles":[],"schemaVersion":1}"#.utf8)
        .write(to: target)
    try FileManager.default.createSymbolicLink(
        at: context.fileURL,
        withDestinationURL: target
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.invalidBackingFile
    ) {
        try await context.store.loadAll()
    }
}

@Test
func profileStoreRejectsHardLinkedBackingFile() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let target = context.directory.appendingPathComponent(
        "target.json",
        isDirectory: false
    )
    try Data(#"{"profiles":[],"schemaVersion":1}"#.utf8)
        .write(to: target)
    try FileManager.default.linkItem(
        at: target,
        to: context.fileURL
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.invalidBackingFile
    ) {
        try await context.store.loadAll()
    }
}

@Test
func profileStoreRejectsDanglingSymlinkBackingFile() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let missingTarget = context.directory.appendingPathComponent(
        "missing.json",
        isDirectory: false
    )
    try FileManager.default.createSymbolicLink(
        at: context.fileURL,
        withDestinationURL: missingTarget
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.invalidBackingFile
    ) {
        try await context.store.loadAll()
    }
}

@Test
func profileStoreRejectsOversizedBackingFileBeforeDecode() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    #expect(
        FileManager.default.createFile(
            atPath: context.fileURL.path,
            contents: nil
        )
    )
    let handle = try FileHandle(forWritingTo: context.fileURL)
    defer { try? handle.close() }
    try handle.truncate(
        atOffset: UInt64(8 * 1024 * 1024 + 1)
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.payloadTooLarge
    ) {
        try await context.store.loadAll()
    }
}

@Test
func profileStoreDoesNotWritePayloadItCannotReadBack() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    var profile = try makeProfile()
    profile.clientID = String(
        repeating: "a",
        count: 8 * 1024 * 1024 + 1
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.payloadTooLarge
    ) {
        try await context.store.save(profile)
    }
    #expect(!FileManager.default.fileExists(atPath: context.fileURL.path))
}

@Test
func profileStoreRejectsFIFOBackingPathWithoutBlocking() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let result = context.fileURL.path.withCString {
        Darwin.mkfifo($0, 0o600)
    }
    #expect(result == 0)

    await #expect(
        throws: GitHubConnectionProfileStoreError.invalidBackingFile
    ) {
        try await context.store.loadAll()
    }
}

@Test
func profileStoreRejectsDirectoryBackingPath() async throws {
    let context = try temporaryProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    try FileManager.default.createDirectory(
        at: context.fileURL,
        withIntermediateDirectories: true
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.invalidBackingFile
    ) {
        try await context.store.loadAll()
    }
}

@Test
func repositoryMonitoringSelectionHonorsAllAndSelectedModes() {
    #expect(GitHubRepositoryMonitoringSelection.allAccessible.includes(repositoryID: 999))

    let selected = GitHubRepositoryMonitoringSelection.selected([10, 20])
    #expect(selected.includes(repositoryID: 10))
    #expect(!selected.includes(repositoryID: 30))
}

private struct TemporaryProfileStore {
    let directory: URL
    let fileURL: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
}

private func temporaryProfileStore() throws -> TemporaryProfileStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchneeBar-profile-tests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("connections.json", isDirectory: false)
    return TemporaryProfileStore(
        directory: directory,
        fileURL: fileURL,
        store: ApplicationSupportGitHubConnectionProfileStore(fileURL: fileURL)
    )
}

private func makeProfile(
    connectionID: UUID = UUID(
        uuidString: "10000000-0000-0000-0000-000000000001"
    )!
) throws -> GitHubConnectionProfile {
    let connection = GitHubConnection(
        id: connectionID,
        displayName: "Personal GitHub",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        serverVersion: nil,
        apiVersion: "2026-03-10"
    )
    return GitHubConnectionProfile(
        connection: connection,
        account: GitHubAccountIdentity(id: "42", login: "octocat"),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client",
        repositorySelection: .allAccessible,
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 1_500)
    )
}
