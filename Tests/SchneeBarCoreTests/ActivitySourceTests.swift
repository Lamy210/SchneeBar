import Foundation
import SchneeBarCore
import Testing

private enum ActivitySourceTestError: Error {
    case failed
}

private actor SequencedActivitySource: ActivitySource {
    nonisolated let id: ActivitySourceID
    private var results: [Result<[ActivityItem], ActivitySourceTestError>]

    init(
        id: ActivitySourceID,
        results: [Result<[ActivityItem], ActivitySourceTestError>]
    ) {
        self.id = id
        self.results = results
    }

    func load() async throws -> [ActivityItem] {
        guard !results.isEmpty else {
            return []
        }

        let result = results.removeFirst()
        switch result {
        case let .success(items):
            return items
        case let .failure(error):
            throw error
        }
    }
}

@Test
func activitySourceEngineCombinesSourcesUsingGlobalInboxOrdering() async {
    let github = SequencedActivitySource(
        id: "github",
        results: [
            .success([
                sourceItem(
                    id: "github:success",
                    repository: "snow/a",
                    state: .success,
                    updatedAt: 300
                ),
                sourceItem(
                    id: "github:failed",
                    repository: "snow/a",
                    state: .failed,
                    updatedAt: 100
                ),
            ]),
        ]
    )
    let other = SequencedActivitySource(
        id: "other",
        results: [
            .success([
                sourceItem(
                    id: "other:running",
                    repository: "other/b",
                    state: .running,
                    updatedAt: 400
                ),
            ]),
        ]
    )
    let engine = ActivitySourceEngine(sources: [github, other])

    let items = await engine.loadAll()

    #expect(items.map(\.id) == [
        "github:failed",
        "other:running",
        "github:success",
    ])
    #expect(await engine.sourceIDs() == ["github", "other"])
}

@Test
func activitySourceFailureKeepsLastKnownGoodWithoutHidingHealthySources() async {
    let stable = SequencedActivitySource(
        id: "stable",
        results: [
            .success([
                sourceItem(
                    id: "stable:item",
                    repository: "stable/repo",
                    state: .success,
                    updatedAt: 100
                ),
            ]),
            .failure(.failed),
        ]
    )
    let fresh = SequencedActivitySource(
        id: "fresh",
        results: [
            .success([]),
            .success([
                sourceItem(
                    id: "fresh:item",
                    repository: "fresh/repo",
                    state: .failed,
                    updatedAt: 200
                ),
            ]),
        ]
    )
    let engine = ActivitySourceEngine(sources: [stable, fresh])

    _ = await engine.loadAll()
    let second = await engine.loadAll()

    #expect(second.map(\.id) == ["fresh:item", "stable:item"])

    let diagnostics = await engine.diagnostics()
    let stableDiagnostic = diagnostics.first { $0.sourceID == "stable" }
    let freshDiagnostic = diagnostics.first { $0.sourceID == "fresh" }

    #expect(stableDiagnostic?.health == .degraded)
    #expect(stableDiagnostic?.consecutiveFailureCount == 1)
    #expect(stableDiagnostic?.isServingLastKnownGood == true)
    #expect(freshDiagnostic?.health == .healthy)
}

@Test
func activitySourceFailureWithoutCacheIsUnavailable() async {
    let source = SequencedActivitySource(
        id: "broken",
        results: [.failure(.failed)]
    )
    let engine = ActivitySourceEngine(sources: [source])

    #expect(await engine.loadAll().isEmpty)

    let diagnostic = await engine.diagnostics().first
    #expect(diagnostic?.health == .unavailable)
    #expect(diagnostic?.isServingLastKnownGood == false)
    #expect(diagnostic?.consecutiveFailureCount == 1)
}

@Test
func duplicateActivityIDsPreferEarlierRegisteredSourceAndReportCollision() async {
    let preferred = SequencedActivitySource(
        id: "preferred",
        results: [
            .success([
                sourceItem(
                    id: "shared",
                    repository: "preferred/repo",
                    state: .failed,
                    updatedAt: 100
                ),
            ]),
        ]
    )
    let duplicate = SequencedActivitySource(
        id: "duplicate",
        results: [
            .success([
                sourceItem(
                    id: "shared",
                    repository: "duplicate/repo",
                    state: .success,
                    updatedAt: 500
                ),
            ]),
        ]
    )
    let engine = ActivitySourceEngine(sources: [preferred, duplicate])

    let items = await engine.loadAll()
    let diagnostics = await engine.diagnostics()

    #expect(items.count == 1)
    #expect(items.first?.repository == "preferred/repo")
    #expect(
        diagnostics.first { $0.sourceID == "duplicate" }?
            .droppedDuplicateItemCount == 1
    )
}

@Test
func replacingSourceClearsOldCachedState() async {
    let original = SequencedActivitySource(
        id: "provider",
        results: [
            .success([
                sourceItem(
                    id: "old",
                    repository: "old/repo",
                    state: .failed,
                    updatedAt: 100
                ),
            ]),
        ]
    )
    let replacement = SequencedActivitySource(
        id: "provider",
        results: [
            .success([
                sourceItem(
                    id: "new",
                    repository: "new/repo",
                    state: .success,
                    updatedAt: 200
                ),
            ]),
        ]
    )
    let engine = ActivitySourceEngine(sources: [original])

    #expect(await engine.loadAll().map(\.id) == ["old"])
    await engine.register(replacement)
    #expect(await engine.currentItems().isEmpty)
    #expect(await engine.loadAll().map(\.id) == ["new"])
    #expect(await engine.sourceIDs() == ["provider"])
}

@Test
func unregisterRemovesCachedActivityImmediately() async {
    let source = SequencedActivitySource(
        id: "provider",
        results: [
            .success([
                sourceItem(
                    id: "item",
                    repository: "repo/name",
                    state: .failed,
                    updatedAt: 100
                ),
            ]),
        ]
    )
    let engine = ActivitySourceEngine(sources: [source])

    _ = await engine.loadAll()
    await engine.unregister(id: "provider")

    #expect(await engine.currentItems().isEmpty)
    #expect(await engine.diagnostics().isEmpty)
}

@Test
func closureActivitySourceForwardsLoaderResult() async throws {
    let source = ClosureActivitySource(id: "closure") {
        [
            sourceItem(
                id: "closure:item",
                repository: "repo/name",
                state: .success,
                updatedAt: 100
            ),
        ]
    }

    #expect(try await source.load().map(\.id) == ["closure:item"])
}

private func sourceItem(
    id: String,
    repository: String,
    state: ActivityState,
    updatedAt: TimeInterval
) -> ActivityItem {
    ActivityItem(
        id: id,
        repository: repository,
        context: "CI",
        detail: state.rawValue,
        state: state,
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
