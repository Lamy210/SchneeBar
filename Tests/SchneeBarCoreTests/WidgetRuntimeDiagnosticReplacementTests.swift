import Foundation
import SchneeBarCore
import Testing

private actor ReplacementDiagnosticProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "diagnostic-replacement",
        displayName: "Diagnostic Replacement",
        refreshPolicy: .interval(10)
    )

    private let succeeds: Bool

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func snapshot() async throws -> WidgetSnapshot {
        guard succeeds else {
            throw Failure.expected
        }

        return Self.snapshot(text: "ok", generatedAt: 123)
    }

    private enum Failure: Error {
        case expected
    }

    fileprivate static func snapshot(
        text: String,
        generatedAt: TimeInterval
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            descriptor: WidgetDescriptor(
                id: "diagnostic-replacement",
                displayName: "Diagnostic Replacement",
                refreshPolicy: .interval(10)
            ),
            generatedAt: Date(timeIntervalSince1970: generatedAt),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(text: text, accessibilityLabel: text),
                normal: .init(text: text, accessibilityLabel: text)
            )
        )
    }
}

private actor InFlightReplacementDiagnosticProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "diagnostic-replacement",
        displayName: "Diagnostic Replacement",
        refreshPolicy: .interval(10)
    )

    private var didStart = false
    private var continuation: CheckedContinuation<WidgetSnapshot, Never>?

    func snapshot() async throws -> WidgetSnapshot {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        didStart
    }

    func finish() {
        continuation?.resume(
            returning: ReplacementDiagnosticProvider.snapshot(
                text: "old",
                generatedAt: 321
            )
        )
        continuation = nil
    }
}

private actor OverlappingDiagnosticProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "diagnostic-replacement",
        displayName: "Diagnostic Replacement",
        refreshPolicy: .interval(10)
    )

    private var continuations: [CheckedContinuation<WidgetSnapshot, Never>?] = []

    func snapshot() async throws -> WidgetSnapshot {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func startedCount() -> Int {
        continuations.count
    }

    func finish(
        index: Int,
        text: String,
        generatedAt: TimeInterval
    ) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index]
        else {
            return
        }
        continuations[index] = nil
        continuation.resume(
            returning: ReplacementDiagnosticProvider.snapshot(
                text: text,
                generatedAt: generatedAt
            )
        )
    }
}

@Test
func replacingProviderClearsSnapshotAndRuntimeDiagnosticHistory() async throws {
    let engine = WidgetEngine(providers: [
        ReplacementDiagnosticProvider(succeeds: true)
    ])
    let firstAttempt = Date(timeIntervalSince1970: 1_000)
    let secondAttempt = Date(timeIntervalSince1970: 2_000)

    _ = await engine.refresh(id: "diagnostic-replacement", at: firstAttempt)
    let healthy = try #require(await engine.diagnostic(id: "diagnostic-replacement"))
    #expect(healthy.health == .healthy)
    #expect(await engine.snapshot(id: "diagnostic-replacement") != nil)

    try await engine.register(ReplacementDiagnosticProvider(succeeds: false))

    let reset = try #require(await engine.diagnostic(id: "diagnostic-replacement"))
    #expect(reset.health == .notLoaded)
    #expect(reset.lastAttemptedAt == nil)
    #expect(reset.lastSucceededAt == nil)
    #expect(reset.lastFailureAt == nil)
    #expect(reset.consecutiveFailureCount == 0)
    #expect(await engine.snapshot(id: "diagnostic-replacement") == nil)

    _ = await engine.refresh(id: "diagnostic-replacement", at: secondAttempt)
    let failed = try #require(await engine.diagnostic(id: "diagnostic-replacement"))
    #expect(failed.health == .unavailable)
    #expect(failed.lastAttemptedAt == secondAttempt)
    #expect(failed.lastSucceededAt == nil)
    #expect(failed.lastFailureAt == secondAttempt)
    #expect(failed.consecutiveFailureCount == 1)
    #expect(!failed.isServingLastKnownGood)
    #expect(await engine.snapshot(id: "diagnostic-replacement") == nil)
}

@Test
func inFlightSnapshotFromReplacedProviderIsDiscarded() async throws {
    let oldProvider = InFlightReplacementDiagnosticProvider()
    let engine = WidgetEngine(providers: [oldProvider])
    let oldAttempt = Date(timeIntervalSince1970: 3_000)

    let oldRefresh = Task {
        await engine.refresh(id: "diagnostic-replacement", at: oldAttempt)
    }

    while !(await oldProvider.hasStarted()) {
        await Task.yield()
    }

    try await engine.register(ReplacementDiagnosticProvider(succeeds: false))
    await oldProvider.finish()
    _ = await oldRefresh.value

    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-replacement"))
    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastAttemptedAt == nil)
    #expect(diagnostic.lastSucceededAt == nil)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
    #expect(await engine.snapshot(id: "diagnostic-replacement") == nil)
}

@Test
func olderOverlappingRefreshCannotOverwriteNewerResult() async throws {
    let provider = OverlappingDiagnosticProvider()
    let engine = WidgetEngine(providers: [provider])
    let olderAttempt = Date(timeIntervalSince1970: 4_000)
    let newerAttempt = Date(timeIntervalSince1970: 4_010)

    let olderRefresh = Task {
        await engine.refresh(id: "diagnostic-replacement", at: olderAttempt)
    }
    while await provider.startedCount() < 1 {
        await Task.yield()
    }

    let newerRefresh = Task {
        await engine.refresh(id: "diagnostic-replacement", at: newerAttempt)
    }
    while await provider.startedCount() < 2 {
        await Task.yield()
    }

    await provider.finish(index: 1, text: "new", generatedAt: 222)
    _ = await newerRefresh.value
    await provider.finish(index: 0, text: "old", generatedAt: 111)
    _ = await olderRefresh.value

    let snapshot = try #require(await engine.snapshot(id: "diagnostic-replacement"))
    let diagnostic = try #require(await engine.diagnostic(id: "diagnostic-replacement"))

    #expect(snapshot.generatedAt == Date(timeIntervalSince1970: 222))
    #expect(diagnostic.lastAttemptedAt == newerAttempt)
    #expect(diagnostic.lastSucceededAt == newerAttempt)
    #expect(diagnostic.snapshotGeneratedAt == Date(timeIntervalSince1970: 222))
}
