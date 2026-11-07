import Foundation
import Testing
@testable import SchneeBarGitHub

private func withPrivateJournalDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("schneebar-journal-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

private func enrollmentForDisk(_ id: UUID = UUID()) throws
    -> GitHubCredentialEnrollmentLifecycle
{
    try GitHubCredentialEnrollmentLifecycle(
        enrollmentID: id, purpose: .read,
        canonicalWebOrigin: "https://github.com",
        numericAccountID: "123", appClientID: "Iv1.integration"
    )
}

@Test
func fileJournalPersistsAndRejectsStaleCrossInstanceWrite() async throws {
    try await withPrivateJournalDirectory { dir in
        let journal1 = GitHubCredentialEnrollmentJournal(
            persistence: GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        )
        let journal2 = GitHubCredentialEnrollmentJournal(
            persistence: GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        )
        let a = try enrollmentForDisk()
        _ = try await journal1.register(a)
        _ = try await journal2.record(for: a.enrollmentID)
        let active = try await journal1.transition(
            enrollmentID: a.enrollmentID, expectedGeneration: 1, to: .dpActive
        )
        await #expect(throws: GitHubCredentialEnrollmentJournalError.staleSnapshot) {
            try await journal2.transition(
                enrollmentID: a.enrollmentID, expectedGeneration: 1, to: .disconnected
            )
        }
        #expect(try await journal2.record(for: a.enrollmentID) == active)
        let reopened = GitHubCredentialEnrollmentJournal(
            persistence: GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        )
        #expect(try await reopened.record(for: a.enrollmentID) == active)
    }
}

@Test
func fileJournalDoesNotOverwriteUnreadableSharedSnapshot() async throws {
    try await withPrivateJournalDirectory { dir in
        let file = dir.appendingPathComponent("enrollments-v1.json")
        try Data("{broken".utf8).write(to: file)
        let store = GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        #expect(throws: GitHubCredentialEnrollmentFileStoreError.corruptFile) {
            try store.compareAndReplace(expected: [], next: [enrollmentForDisk()])
        }
        #expect(try Data(contentsOf: file) == Data("{broken".utf8))
    }
}

@Test
func fileJournalRejectsUnsafeDirectoryAndSymlinkedPayload() async throws {
    try await withPrivateJournalDirectory { dir in
        let unsafe = dir.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(
            at: unsafe, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: unsafe.path
        )
        let bad = GitHubCredentialEnrollmentFileJournalStore(directoryURL: unsafe)
        #expect(throws: GitHubCredentialEnrollmentFileStoreError.unsafeStorage) {
            try bad.load()
        }

        let sensitive = dir.appendingPathComponent("somewhere.json")
        try Data("{}".utf8).write(to: sensitive)
        let file = dir.appendingPathComponent("enrollments-v1.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sensitive)
        let good = GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        #expect(throws: any Error) { try good.load() }
        #expect(try Data(contentsOf: sensitive) == Data("{}".utf8))
    }
}

@Test
func fileJournalRejectsUnknownSchemaWithoutChangingBytes() async throws {
    try await withPrivateJournalDirectory { dir in
        let file = dir.appendingPathComponent("enrollments-v1.json")
        let bytes = Data("{\"version\":999,\"records\":[]}".utf8)
        try bytes.write(to: file)
        let store = GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        #expect(throws: GitHubCredentialEnrollmentFileStoreError.unsupportedFormat) {
            try store.load()
        }
        #expect(try Data(contentsOf: file) == bytes)
    }
}

@Test
func fileJournalDoesNotReuseEnrolledUUIDAcrossReconnect() async throws {
    try await withPrivateJournalDirectory { dir in
        let journal = GitHubCredentialEnrollmentJournal(
            persistence: GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        )
        let old = try enrollmentForDisk()
        _ = try await journal.register(old)
        let disconnected = try await journal.transition(
            enrollmentID: old.enrollmentID, expectedGeneration: 1, to: .disconnected
        )
        let newer = try enrollmentForDisk()
        _ = try await journal.register(newer)
        let scope = try #require(disconnected.disconnectedCleanupScope)
        #expect(disconnected.matchesDisconnectedCleanup(scope))
        #expect(!newer.matchesDisconnectedCleanup(scope))
        let restarted = GitHubCredentialEnrollmentJournal(
            persistence: GitHubCredentialEnrollmentFileJournalStore(directoryURL: dir)
        )
        #expect(try await restarted.record(for: old.enrollmentID) == disconnected)
        #expect(try await restarted.record(for: newer.enrollmentID) == newer)
    }
}
