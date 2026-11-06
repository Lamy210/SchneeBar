import Foundation
import SchneeBarCore
import Testing

private actor DiagnosticSequenceProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "diagnostic-sequence",
        displayName: "Diagnostic Sequence",
        refreshPolicy: .interval(10)
    )

    private var outcomes: [Bool]

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func snapshot() async throws -> WidgetSnapshot {
        let succeeds = outcomes.isEmpty ? true : outcomes.removeFirst()
        guard succeeds else {
            throw Failure.expected
        }

        return WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 123),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(text: "ok", accessibilityLabel: "ok"),
                normal: .init(text: "ok", accessibilityLabel: "ok")
            )
        )
    }

    private enum Failure: Error {
        case expected
    }
}

@Test
func diagnosticsStartNotLoadedWithoutInventingFailure() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [true])
    let engine = WidgetEngine(providers: [provider])

    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-sequence"))

    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastAttemptedAt == nil)
    #expect(diagnostic.lastSucceededAt == nil)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
    #expect(!diagnostic.isServingLastKnownGood)
    #expect(diagnostic.snapshotGeneratedAt == nil)
}

@Test
func diagnosticsBecomeHealthyAfterSuccess() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [true])
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 1_000)

    _ = await engine.refresh(id: "diagnostic-sequence", at: attemptedAt)
    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-sequence"))

    #expect(diagnostic.health == .healthy)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastSucceededAt == attemptedAt)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
    #expect(!diagnostic.isServingLastKnownGood)
    #expect(diagnostic.snapshotGeneratedAt == Date(timeIntervalSince1970: 123))
}

@Test
func diagnosticsExposeDegradedLastKnownGoodAfterFailure() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [true, false, false])
    let engine = WidgetEngine(providers: [provider])
    let first = Date(timeIntervalSince1970: 1_000)
    let second = Date(timeIntervalSince1970: 1_010)
    let third = Date(timeIntervalSince1970: 1_020)

    _ = await engine.refresh(id: "diagnostic-sequence", at: first)
    _ = await engine.refresh(id: "diagnostic-sequence", at: second)
    _ = await engine.refresh(id: "diagnostic-sequence", at: third)
    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-sequence"))

    #expect(diagnostic.health == .degraded)
    #expect(diagnostic.lastAttemptedAt == third)
    #expect(diagnostic.lastSucceededAt == first)
    #expect(diagnostic.lastFailureAt == third)
    #expect(diagnostic.consecutiveFailureCount == 2)
    #expect(diagnostic.isServingLastKnownGood)
    #expect(diagnostic.snapshotGeneratedAt == Date(timeIntervalSince1970: 123))
}

@Test
func diagnosticsExposeUnavailableWhenNoSnapshotEverSucceeded() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [false])
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 2_000)

    _ = await engine.refresh(id: "diagnostic-sequence", at: attemptedAt)
    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-sequence"))

    #expect(diagnostic.health == .unavailable)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastSucceededAt == nil)
    #expect(diagnostic.lastFailureAt == attemptedAt)
    #expect(diagnostic.consecutiveFailureCount == 1)
    #expect(!diagnostic.isServingLastKnownGood)
    #expect(diagnostic.snapshotGeneratedAt == nil)
}

@Test
func successfulRefreshRecoversHealthAndResetsConsecutiveFailures() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [false, true])
    let engine = WidgetEngine(providers: [provider])
    let failureAt = Date(timeIntervalSince1970: 3_000)
    let successAt = Date(timeIntervalSince1970: 3_010)

    _ = await engine.refresh(id: "diagnostic-sequence", at: failureAt)
    _ = await engine.refresh(id: "diagnostic-sequence", at: successAt)
    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-sequence"))

    #expect(diagnostic.health == .healthy)
    #expect(diagnostic.lastAttemptedAt == successAt)
    #expect(diagnostic.lastSucceededAt == successAt)
    #expect(diagnostic.lastFailureAt == failureAt)
    #expect(diagnostic.consecutiveFailureCount == 0)
    #expect(!diagnostic.isServingLastKnownGood)
}

@Test
func unregisterRemovesRuntimeDiagnostics() async {
    let provider = DiagnosticSequenceProvider(outcomes: [false])
    let engine = WidgetEngine(providers: [provider])

    _ = await engine.refresh(id: "diagnostic-sequence")
    await engine.unregister(id: "diagnostic-sequence")

    #expect(await engine.diagnostic(id: "diagnostic-sequence") == nil)
    #expect(await engine.diagnostics().isEmpty)
}

@Test
func widgetPresentationKeepsStaleReadingAndDiagnosticsTogether() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [true, false, false, true])
    let engine = WidgetEngine(providers: [provider])
    let first = Date(timeIntervalSince1970: 1_000)
    let failed = Date(timeIntervalSince1970: 1_010)
    let failedAgain = Date(timeIntervalSince1970: 1_020)
    let recovered = Date(timeIntervalSince1970: 1_030)

    _ = await engine.refresh(id: "diagnostic-sequence", at: first)
    let healthy = await engine.currentPresentation()
    let healthySnapshot = try #require(healthy.snapshots.first)
    let healthyDiagnostic = try #require(healthy.diagnostics.first {
        $0.descriptor.id == healthySnapshot.descriptor.id
    })
    #expect(healthyDiagnostic.health == .healthy)
    #expect(!healthyDiagnostic.indicatesStaleReading(for: healthySnapshot))

    _ = await engine.refresh(id: "diagnostic-sequence", at: failed)
    _ = await engine.refresh(id: "diagnostic-sequence", at: failedAgain)
    let stale = await engine.currentPresentation()
    let staleSnapshot = try #require(stale.snapshots.first)
    let staleDiagnostic = try #require(stale.diagnostics.first {
        $0.descriptor.id == staleSnapshot.descriptor.id
    })
    #expect(staleSnapshot == healthySnapshot)
    #expect(staleDiagnostic.health == .degraded)
    #expect(staleDiagnostic.consecutiveFailureCount == 2)
    #expect(staleDiagnostic.lastSucceededAt == first)
    #expect(staleDiagnostic.indicatesStaleReading(for: staleSnapshot))

    _ = await engine.refresh(id: "diagnostic-sequence", at: recovered)
    let fresh = await engine.currentPresentation()
    let freshSnapshot = try #require(fresh.snapshots.first)
    let freshDiagnostic = try #require(fresh.diagnostics.first {
        $0.descriptor.id == freshSnapshot.descriptor.id
    })
    #expect(freshDiagnostic.health == .healthy)
    #expect(!freshDiagnostic.indicatesStaleReading(for: freshSnapshot))
}

@Test
func widgetPresentationDoesNotMarkAnUnrelatedSnapshotAsStale() async throws {
    let provider = DiagnosticSequenceProvider(outcomes: [true, false])
    let engine = WidgetEngine(providers: [provider])
    _ = await engine.refresh(id: "diagnostic-sequence")
    _ = await engine.refresh(id: "diagnostic-sequence")

    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-sequence"))
    let unrelatedDescriptor = WidgetDescriptor(
        id: "different-provider",
        displayName: "Different Provider",
        refreshPolicy: .interval(5)
    )
    let unrelatedSnapshot = WidgetSnapshot(
        descriptor: unrelatedDescriptor,
        severity: .nominal,
        priority: .normal,
        representations: .init(
            compact: .init(text: "ok", accessibilityLabel: "ok"),
            normal: .init(text: "ok", accessibilityLabel: "ok")
        )
    )
    #expect(diagnostic.isServingLastKnownGood)
    #expect(!diagnostic.indicatesStaleReading(for: unrelatedSnapshot))
}
