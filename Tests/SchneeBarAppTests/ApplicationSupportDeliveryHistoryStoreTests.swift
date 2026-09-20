@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

@Test
func applicationSupportDeliveryHistoryStoreRoundTripsAcrossInstances() async throws {
    let fixture = try historyStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let scope = DeliveryHistoryStorageScope(
        sourceID: "source-a",
        repositoryID: "42"
    )
    let snapshot = deliveryStoreSnapshot(
        repository: "snow/repo",
        entries: [
            deliveryStoreEntry(id: "run-1", occurredAt: 100),
            deliveryStoreEntry(id: "run-2", occurredAt: 200),
        ]
    )

    try await fixture.store.save(snapshot, scope: scope)

    let recreated = ApplicationSupportDeliveryHistoryStore(
        fileURL: fixture.fileURL,
        now: { Date(timeIntervalSince1970: 999) }
    )
    #expect(try await recreated.load(scope: scope) == snapshot)
}

@Test
func applicationSupportDeliveryHistoryStoreReturnsNilWhenMissing() async throws {
    let fixture = try historyStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let value = try await fixture.store.load(
        scope: DeliveryHistoryStorageScope(
            sourceID: "missing",
            repositoryID: "42"
        )
    )

    #expect(value == nil)
}

@Test
func applicationSupportDeliveryHistoryStoreRejectsUnknownSchema() async throws {
    let fixture = try historyStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    try FileManager.default.createDirectory(
        at: fixture.directory,
        withIntermediateDirectories: true
    )
    try Data(#"{"schemaVersion":999,"records":[]}"#.utf8)
        .write(to: fixture.fileURL, options: .atomic)

    await #expect(
        throws: DeliveryHistoryStoreError.unsupportedSchemaVersion(999)
    ) {
        _ = try await fixture.store.load(
            scope: DeliveryHistoryStorageScope(
                sourceID: "source",
                repositoryID: "repo"
            )
        )
    }
}

@Test
func applicationSupportDeliveryHistoryStoreCapsOneScopeAtTwoHundredEntries() async throws {
    let fixture = try historyStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let scope = DeliveryHistoryStorageScope(
        sourceID: "source",
        repositoryID: "42"
    )
    let snapshot = deliveryStoreSnapshot(
        repository: "snow/repo",
        entries: (0 ..< 250).map { index in
            deliveryStoreEntry(
                id: "run-\(index)",
                occurredAt: TimeInterval(index)
            )
        }
    )

    try await fixture.store.save(snapshot, scope: scope)
    let stored = try #require(await fixture.store.load(scope: scope))

    #expect(stored.entries.count == 200)
    #expect(stored.entries.first?.id == "run-249")
    #expect(stored.entries.last?.id == "run-50")
}

@Test
func applicationSupportDeliveryHistoryStoreCapsGlobalScopesAtOneHundred() async throws {
    let clock = HistoryStoreClock()
    let fixture = try historyStoreFixture(now: { clock.next() })
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    for index in 0 ..< 105 {
        try await fixture.store.save(
            deliveryStoreSnapshot(
                repository: "snow/repo-\(index)",
                entries: [
                    deliveryStoreEntry(
                        id: "run-\(index)",
                        occurredAt: TimeInterval(index)
                    ),
                ]
            ),
            scope: DeliveryHistoryStorageScope(
                sourceID: "source",
                repositoryID: String(index)
            )
        )
    }

    #expect(
        try await fixture.store.load(
            scope: DeliveryHistoryStorageScope(
                sourceID: "source",
                repositoryID: "0"
            )
        ) == nil
    )
    #expect(
        try await fixture.store.load(
            scope: DeliveryHistoryStorageScope(
                sourceID: "source",
                repositoryID: "104"
            )
        ) != nil
    )
}

@Test
func applicationSupportDeliveryHistoryStoreDeletesOnlyRequestedSource() async throws {
    let fixture = try historyStoreFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let first = DeliveryHistoryStorageScope(
        sourceID: "source-a",
        repositoryID: "42"
    )
    let second = DeliveryHistoryStorageScope(
        sourceID: "source-b",
        repositoryID: "42"
    )
    let snapshot = deliveryStoreSnapshot(
        repository: "snow/repo",
        entries: [deliveryStoreEntry(id: "run", occurredAt: 100)]
    )

    try await fixture.store.save(snapshot, scope: first)
    try await fixture.store.save(snapshot, scope: second)
    try await fixture.store.delete(sourceID: "source-a")

    #expect(try await fixture.store.load(scope: first) == nil)
    #expect(try await fixture.store.load(scope: second) == snapshot)
}

private final class HistoryStoreClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return Date(timeIntervalSince1970: value)
    }
}

private struct HistoryStoreFixture {
    let directory: URL
    let fileURL: URL
    let store: ApplicationSupportDeliveryHistoryStore
}

private func historyStoreFixture(
    now: @escaping @Sendable () -> Date = {
        Date(timeIntervalSince1970: 100)
    }
) throws -> HistoryStoreFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory
        .appendingPathComponent("delivery-history-v1.json")

    return HistoryStoreFixture(
        directory: directory,
        fileURL: fileURL,
        store: ApplicationSupportDeliveryHistoryStore(
            fileURL: fileURL,
            now: now
        )
    )
}

private func deliveryStoreSnapshot(
    repository: String,
    entries: [DeliveryHistoryEntry]
) -> DeliveryHistorySnapshot {
    DeliveryHistorySnapshot(
        repository: repository,
        entries: entries
    )
}

private func deliveryStoreEntry(
    id: String,
    occurredAt: TimeInterval
) -> DeliveryHistoryEntry {
    DeliveryHistoryEntry(
        id: id,
        title: "CI",
        detail: "Completed",
        state: .neutral,
        occurredAt: Date(timeIntervalSince1970: occurredAt)
    )
}
