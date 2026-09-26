import Foundation
import SchneeBarCore
import Testing

private struct StubWidgetProvider: WidgetProvider {
    let descriptor: WidgetDescriptor
    let value: WidgetSnapshot

    func snapshot() async throws -> WidgetSnapshot {
        value
    }
}

private actor FlakyWidgetProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "flaky",
        displayName: "Flaky",
        refreshPolicy: .interval(5)
    )

    private var calls = 0

    func snapshot() async throws -> WidgetSnapshot {
        calls += 1
        guard calls == 1 else {
            throw Failure.expected
        }

        return makeSnapshot(
            descriptor: descriptor,
            severity: .active,
            priority: .attention,
            text: "working"
        )
    }

    private enum Failure: Error {
        case expected
    }
}

private actor CountingWidgetProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "counting",
        displayName: "Counting",
        refreshPolicy: .interval(10)
    )

    private var calls = 0

    func snapshot() async throws -> WidgetSnapshot {
        calls += 1
        return makeSnapshot(
            descriptor: descriptor,
            severity: .nominal,
            priority: .normal,
            text: "count \(calls)"
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor AlwaysFailingWidgetProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "always-failing",
        displayName: "Always Failing",
        refreshPolicy: .interval(10)
    )

    private var calls = 0

    func snapshot() async throws -> WidgetSnapshot {
        calls += 1
        throw Failure.expected
    }

    func callCount() -> Int {
        calls
    }

    private enum Failure: Error {
        case expected
    }
}

private actor SnapshotContractProvider: WidgetProvider {
    nonisolated let descriptor: WidgetDescriptor
    private var snapshots: [WidgetSnapshot]

    init(
        descriptor: WidgetDescriptor,
        snapshots: [WidgetSnapshot]
    ) {
        self.descriptor = descriptor
        self.snapshots = snapshots
    }

    func snapshot() async throws -> WidgetSnapshot {
        guard !snapshots.isEmpty else {
            throw SnapshotContractError.exhausted
        }
        return snapshots.removeFirst()
    }

    private enum SnapshotContractError: Error {
        case exhausted
    }
}

private final class MutableDescriptorWidgetProvider:
    WidgetProvider,
    @unchecked Sendable
{
    var descriptor: WidgetDescriptor

    init(descriptor: WidgetDescriptor) {
        self.descriptor = descriptor
    }

    func snapshot() async throws -> WidgetSnapshot {
        makeSnapshot(
            descriptor: descriptor,
            severity: .nominal,
            priority: .normal,
            text: "current"
        )
    }
}

private final class SequencedDescriptorWidgetProvider:
    WidgetProvider,
    @unchecked Sendable
{
    private let firstDescriptor: WidgetDescriptor
    private let laterDescriptor: WidgetDescriptor
    private(set) var descriptorReadCount = 0

    var descriptor: WidgetDescriptor {
        descriptorReadCount += 1
        return descriptorReadCount == 1
            ? firstDescriptor
            : laterDescriptor
    }

    init(
        firstDescriptor: WidgetDescriptor,
        laterDescriptor: WidgetDescriptor
    ) {
        self.firstDescriptor = firstDescriptor
        self.laterDescriptor = laterDescriptor
    }

    func snapshot() async throws -> WidgetSnapshot {
        makeSnapshot(
            descriptor: firstDescriptor,
            severity: .nominal,
            priority: .normal,
            text: "stable"
        )
    }
}

private enum CancellationWidgetBehavior: Sendable {
    case success(WidgetSnapshot)
    case throwCancellation
    case cancelThenSuccess(WidgetSnapshot)
    case cancelThenFailure
}

private enum CancellationWidgetTestError: Error {
    case expected
    case exhausted
}

private actor CancellationWidgetProvider: WidgetProvider {
    nonisolated let descriptor: WidgetDescriptor
    private var behaviors: [CancellationWidgetBehavior]
    private var calls = 0

    init(
        descriptor: WidgetDescriptor,
        behaviors: [CancellationWidgetBehavior]
    ) {
        self.descriptor = descriptor
        self.behaviors = behaviors
    }

    func snapshot() async throws -> WidgetSnapshot {
        calls += 1
        guard !behaviors.isEmpty else {
            throw CancellationWidgetTestError.exhausted
        }

        let behavior = behaviors.removeFirst()
        switch behavior {
        case let .success(snapshot):
            return snapshot

        case .throwCancellation:
            throw CancellationError()

        case let .cancelThenSuccess(snapshot):
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return snapshot

        case .cancelThenFailure:
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            throw CancellationWidgetTestError.expected
        }
    }

    func callCount() -> Int {
        calls
    }
}

@Test
func widgetVisibilityPoliciesUseSeverity() {
    #expect(WidgetVisibilityPolicy.always.isVisible(for: .nominal))
    #expect(!WidgetVisibilityPolicy.whenNotNominal.isVisible(for: .nominal))
    #expect(WidgetVisibilityPolicy.whenNotNominal.isVisible(for: .active))
    #expect(!WidgetVisibilityPolicy.minimumSeverity(.attention).isVisible(for: .active))
    #expect(WidgetVisibilityPolicy.minimumSeverity(.attention).isVisible(for: .critical))
}

@Test
func automaticRefreshIntervalsHaveOneSecondFloor() {
    #expect(WidgetRefreshPolicy.interval(0).interval(for: .nominal) == 1)
    #expect(WidgetRefreshPolicy.adaptive(active: 0, idle: -2).interval(for: .active) == 1)
    #expect(WidgetRefreshPolicy.adaptive(active: 0, idle: -2).interval(for: .nominal) == 1)
}

@Test
func criticalRepresentationFallsBackToNormal() {
    let descriptor = WidgetDescriptor(id: "fallback", displayName: "Fallback")
    let snapshot = WidgetSnapshot(
        descriptor: descriptor,
        severity: .nominal,
        priority: .normal,
        representations: .init(
            compact: .init(text: "C", accessibilityLabel: "Compact"),
            normal: .init(text: "Normal", accessibilityLabel: "Normal")
        )
    )

    #expect(snapshot.content(for: .critical).text == "Normal")
}

@Test
func widgetEngineFiltersAndOrdersVisibleSnapshots() async {
    let normalDescriptor = WidgetDescriptor(
        id: "normal",
        displayName: "Normal",
        visibilityPolicy: .always
    )
    let criticalDescriptor = WidgetDescriptor(
        id: "critical",
        displayName: "Critical",
        visibilityPolicy: .always
    )
    let hiddenDescriptor = WidgetDescriptor(
        id: "hidden",
        displayName: "Hidden",
        visibilityPolicy: .whenNotNominal
    )

    let engine = WidgetEngine(providers: [
        StubWidgetProvider(
            descriptor: normalDescriptor,
            value: makeSnapshot(
                descriptor: normalDescriptor,
                severity: .nominal,
                priority: .normal,
                text: "normal"
            )
        ),
        StubWidgetProvider(
            descriptor: criticalDescriptor,
            value: makeSnapshot(
                descriptor: criticalDescriptor,
                severity: .critical,
                priority: .critical,
                text: "critical"
            )
        ),
        StubWidgetProvider(
            descriptor: hiddenDescriptor,
            value: makeSnapshot(
                descriptor: hiddenDescriptor,
                severity: .nominal,
                priority: .background,
                text: "hidden"
            )
        ),
    ])

    let snapshots = await engine.refreshAll()

    #expect(snapshots.map(\.descriptor.id.rawValue) == ["critical", "normal"])
}

@Test
func widgetEnginePreservesLastKnownGoodSnapshotAfterProviderFailure() async {
    let provider = FlakyWidgetProvider()
    let engine = WidgetEngine(providers: [provider])

    let first = await engine.refresh(id: "flaky")
    let second = await engine.refresh(id: "flaky")

    #expect(first?.content().text == "working")
    #expect(second == first)
}

@Test
func widgetEngineRejectsSnapshotWithDifferentProviderID() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.status",
        displayName: "Provider Status"
    )
    let mismatched = makeSnapshot(
        descriptor: WidgetDescriptor(
            id: "../malformed",
            displayName: "Injected"
        ),
        severity: .critical,
        priority: .critical,
        text: "injected"
    )
    let provider = SnapshotContractProvider(
        descriptor: descriptor,
        snapshots: [mismatched]
    )
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 3_000)

    let result = await engine.refresh(
        id: descriptor.id,
        at: attemptedAt
    )

    #expect(result == nil)
    #expect(await engine.snapshot(id: descriptor.id) == nil)
    #expect(await engine.orderedVisibleSnapshots().isEmpty)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.descriptor == descriptor)
    #expect(diagnostic.health == .unavailable)
    #expect(diagnostic.lastFailureAt == attemptedAt)
    #expect(diagnostic.consecutiveFailureCount == 1)
    #expect(!diagnostic.isServingLastKnownGood)
}

@Test
func widgetEngineRejectsSnapshotDescriptorPolicyDriftWithSameID() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.status",
        displayName: "Provider Status",
        defaultIsEnabled: true,
        defaultOrder: 10,
        visibilityPolicy: .always,
        refreshPolicy: .interval(30)
    )
    let drifted = makeSnapshot(
        descriptor: WidgetDescriptor(
            id: descriptor.id,
            displayName: "Changed Name",
            defaultIsEnabled: false,
            defaultOrder: 999,
            visibilityPolicy: .whenNotNominal,
            refreshPolicy: .manual
        ),
        severity: .nominal,
        priority: .normal,
        text: "drifted"
    )
    let provider = SnapshotContractProvider(
        descriptor: descriptor,
        snapshots: [drifted]
    )
    let engine = WidgetEngine(providers: [provider])

    _ = await engine.refresh(id: descriptor.id)

    #expect(await engine.snapshot(id: descriptor.id) == nil)
    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.descriptor == descriptor)
    #expect(diagnostic.health == .unavailable)
}

@Test
func singleRegistrationCapturesProviderDescriptorExactlyOnce() async throws {
    let registered = WidgetDescriptor(
        id: "provider.single",
        displayName: "Registered"
    )
    let later = WidgetDescriptor(
        id: "../invalid",
        displayName: "Later"
    )
    let provider = SequencedDescriptorWidgetProvider(
        firstDescriptor: registered,
        laterDescriptor: later
    )
    let engine = WidgetEngine()

    try await engine.register(provider)

    #expect(provider.descriptorReadCount == 1)
    #expect(await engine.descriptors() == [registered])

    let snapshot = await engine.refresh(id: registered.id)
    #expect(snapshot?.descriptor == registered)
    #expect(provider.descriptorReadCount == 1)
}

@Test
func groupReplacementCapturesEachProviderDescriptorExactlyOnce() async throws {
    let registered = WidgetDescriptor(
        id: "provider.grouped",
        displayName: "Registered"
    )
    let later = WidgetDescriptor(
        id: "invalid/provider",
        displayName: "Later"
    )
    let provider = SequencedDescriptorWidgetProvider(
        firstDescriptor: registered,
        laterDescriptor: later
    )
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: WidgetProviderGroupID(rawValue: "provider.widgets"),
        with: [provider]
    )

    #expect(provider.descriptorReadCount == 1)
    #expect(await engine.descriptors() == [registered])

    let snapshot = await engine.refresh(id: registered.id)
    #expect(snapshot?.descriptor == registered)
    #expect(provider.descriptorReadCount == 1)
}

@Test
func widgetEngineKeepsRegistrationDescriptorAuthoritativeAfterProviderDrift() async throws {
    let registered = WidgetDescriptor(
        id: "provider.status",
        displayName: "Registered",
        defaultOrder: 10,
        refreshPolicy: .interval(30)
    )
    let provider = MutableDescriptorWidgetProvider(
        descriptor: registered
    )
    let engine = WidgetEngine(providers: [provider])

    provider.descriptor = WidgetDescriptor(
        id: registered.id,
        displayName: "Mutated",
        defaultOrder: 999,
        visibilityPolicy: .whenNotNominal,
        refreshPolicy: .manual
    )

    #expect(await engine.descriptors() == [registered])

    _ = await engine.refresh(id: registered.id)

    #expect(await engine.snapshot(id: registered.id) == nil)
    let diagnostic = try #require(
        await engine.diagnostic(id: registered.id)
    )
    #expect(diagnostic.descriptor == registered)
    #expect(diagnostic.health == .unavailable)
}

@Test
func widgetEnginePreservesLastKnownGoodAfterSnapshotDescriptorMismatch() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.status",
        displayName: "Provider Status"
    )
    let good = makeSnapshot(
        descriptor: descriptor,
        severity: .active,
        priority: .attention,
        text: "good"
    )
    let mismatched = makeSnapshot(
        descriptor: WidgetDescriptor(
            id: "provider.other",
            displayName: "Other Provider"
        ),
        severity: .critical,
        priority: .critical,
        text: "bad"
    )
    let provider = SnapshotContractProvider(
        descriptor: descriptor,
        snapshots: [good, mismatched]
    )
    let engine = WidgetEngine(providers: [provider])
    let firstAttempt = Date(timeIntervalSince1970: 4_000)
    let secondAttempt = Date(timeIntervalSince1970: 4_100)

    let first = await engine.refresh(
        id: descriptor.id,
        at: firstAttempt
    )
    let second = await engine.refresh(
        id: descriptor.id,
        at: secondAttempt
    )

    #expect(first == good)
    #expect(second == good)
    #expect(await engine.snapshot(id: descriptor.id) == good)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.descriptor == descriptor)
    #expect(diagnostic.health == .degraded)
    #expect(diagnostic.lastSucceededAt == firstAttempt)
    #expect(diagnostic.lastFailureAt == secondAttempt)
    #expect(diagnostic.consecutiveFailureCount == 1)
    #expect(diagnostic.isServingLastKnownGood)
    #expect(diagnostic.snapshotGeneratedAt == good.generatedAt)
}

@Test
func widgetRefreshSkipsProviderWhenTaskIsAlreadyCancelled() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.cancel.preflight",
        displayName: "Preflight Cancellation"
    )
    let snapshot = makeSnapshot(
        descriptor: descriptor,
        severity: .nominal,
        priority: .normal,
        text: "should not load"
    )
    let provider = CancellationWidgetProvider(
        descriptor: descriptor,
        behaviors: [.success(snapshot)]
    )
    let engine = WidgetEngine(providers: [provider])

    let result = await Task {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return await engine.refresh(
            id: descriptor.id,
            at: Date(timeIntervalSince1970: 5_000)
        )
    }.value

    #expect(result == nil)
    #expect(await provider.callCount() == 0)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastAttemptedAt == nil)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
}

@Test
func widgetRefreshTreatsCancellationErrorAsNeutral() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.cancel.error",
        displayName: "Cancellation Error"
    )
    let provider = CancellationWidgetProvider(
        descriptor: descriptor,
        behaviors: [.throwCancellation]
    )
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 5_100)

    let result = await engine.refresh(
        id: descriptor.id,
        at: attemptedAt
    )

    #expect(result == nil)
    #expect(await provider.callCount() == 1)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
}

@Test
func widgetRefreshCancellationPreservesHealthyLastKnownGood() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.cancel.last_good",
        displayName: "Cancellation Last Good"
    )
    let good = makeSnapshot(
        descriptor: descriptor,
        severity: .active,
        priority: .attention,
        text: "good"
    )
    let provider = CancellationWidgetProvider(
        descriptor: descriptor,
        behaviors: [.success(good), .throwCancellation]
    )
    let engine = WidgetEngine(providers: [provider])
    let firstAttempt = Date(timeIntervalSince1970: 5_200)
    let cancelledAttempt = Date(timeIntervalSince1970: 5_300)

    let first = await engine.refresh(
        id: descriptor.id,
        at: firstAttempt
    )
    let second = await engine.refresh(
        id: descriptor.id,
        at: cancelledAttempt
    )

    #expect(first == good)
    #expect(second == good)
    #expect(await engine.snapshot(id: descriptor.id) == good)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .healthy)
    #expect(diagnostic.lastAttemptedAt == cancelledAttempt)
    #expect(diagnostic.lastSucceededAt == firstAttempt)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
    #expect(!diagnostic.isServingLastKnownGood)
}

@Test
func widgetRefreshTaskCancellationWinsOverConcurrentFailure() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.cancel.failure",
        displayName: "Cancellation Failure"
    )
    let provider = CancellationWidgetProvider(
        descriptor: descriptor,
        behaviors: [.cancelThenFailure]
    )
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 5_400)

    let result = await Task {
        await engine.refresh(
            id: descriptor.id,
            at: attemptedAt
        )
    }.value

    #expect(result == nil)
    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
}

@Test
func widgetRefreshDoesNotApplySnapshotReturnedAfterTaskCancellation() async throws {
    let descriptor = WidgetDescriptor(
        id: "provider.cancel.success",
        displayName: "Cancellation Success"
    )
    let snapshot = makeSnapshot(
        descriptor: descriptor,
        severity: .critical,
        priority: .critical,
        text: "must not apply"
    )
    let provider = CancellationWidgetProvider(
        descriptor: descriptor,
        behaviors: [.cancelThenSuccess(snapshot)]
    )
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 5_500)

    let result = await Task {
        await engine.refresh(
            id: descriptor.id,
            at: attemptedAt
        )
    }.value

    #expect(result == nil)
    #expect(await engine.snapshot(id: descriptor.id) == nil)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
}

@Test
func refreshAllStopsBeforeLaterProvidersAfterCancellation() async {
    let firstDescriptor = WidgetDescriptor(
        id: "provider.cancel.first",
        displayName: "First",
        defaultOrder: 0
    )
    let secondDescriptor = WidgetDescriptor(
        id: "provider.cancel.second",
        displayName: "Second",
        defaultOrder: 1
    )
    let firstSnapshot = makeSnapshot(
        descriptor: firstDescriptor,
        severity: .nominal,
        priority: .normal,
        text: "first"
    )
    let secondSnapshot = makeSnapshot(
        descriptor: secondDescriptor,
        severity: .nominal,
        priority: .normal,
        text: "second"
    )
    let first = CancellationWidgetProvider(
        descriptor: firstDescriptor,
        behaviors: [.cancelThenSuccess(firstSnapshot)]
    )
    let second = CancellationWidgetProvider(
        descriptor: secondDescriptor,
        behaviors: [.success(secondSnapshot)]
    )
    let engine = WidgetEngine(providers: [first, second])

    let snapshots = await Task {
        await engine.refreshAll(
            at: Date(timeIntervalSince1970: 5_600)
        )
    }.value

    #expect(snapshots.isEmpty)
    #expect(await first.callCount() == 1)
    #expect(await second.callCount() == 0)
}

@Test
func refreshDueStopsBeforeLaterProvidersAfterCancellation() async {
    let firstDescriptor = WidgetDescriptor(
        id: "provider.cancel.due_first",
        displayName: "Due First",
        defaultOrder: 0,
        refreshPolicy: .interval(10)
    )
    let secondDescriptor = WidgetDescriptor(
        id: "provider.cancel.due_second",
        displayName: "Due Second",
        defaultOrder: 1,
        refreshPolicy: .interval(10)
    )
    let firstSnapshot = makeSnapshot(
        descriptor: firstDescriptor,
        severity: .nominal,
        priority: .normal,
        text: "first"
    )
    let secondSnapshot = makeSnapshot(
        descriptor: secondDescriptor,
        severity: .nominal,
        priority: .normal,
        text: "second"
    )
    let first = CancellationWidgetProvider(
        descriptor: firstDescriptor,
        behaviors: [.cancelThenSuccess(firstSnapshot)]
    )
    let second = CancellationWidgetProvider(
        descriptor: secondDescriptor,
        behaviors: [.success(secondSnapshot)]
    )
    let engine = WidgetEngine(providers: [first, second])

    let snapshots = await Task {
        await engine.refreshDue(
            at: Date(timeIntervalSince1970: 5_700)
        )
    }.value

    #expect(snapshots.isEmpty)
    #expect(await first.callCount() == 1)
    #expect(await second.callCount() == 0)
}

@Test
func widgetEngineRefreshesOnlyWhenPolicyIsDue() async {
    let provider = CountingWidgetProvider()
    let engine = WidgetEngine(providers: [provider])
    let start = Date(timeIntervalSince1970: 1_000)

    _ = await engine.refreshDue(at: start)
    #expect(await provider.callCount() == 1)
    #expect(await engine.secondsUntilNextRefresh(at: start) == 10)

    _ = await engine.refreshDue(at: start.addingTimeInterval(5))
    #expect(await provider.callCount() == 1)

    _ = await engine.refreshDue(at: start.addingTimeInterval(10))
    #expect(await provider.callCount() == 2)
}

@Test
func initialProviderFailureStillRespectsRefreshPolicy() async {
    let provider = AlwaysFailingWidgetProvider()
    let engine = WidgetEngine(providers: [provider])
    let start = Date(timeIntervalSince1970: 2_000)

    _ = await engine.refreshDue(at: start)
    #expect(await provider.callCount() == 1)
    #expect(await engine.secondsUntilNextRefresh(at: start) == 10)

    _ = await engine.refreshDue(at: start.addingTimeInterval(1))
    #expect(await provider.callCount() == 1)

    _ = await engine.refreshDue(at: start.addingTimeInterval(10))
    #expect(await provider.callCount() == 2)
}

private func makeSnapshot(
    descriptor: WidgetDescriptor,
    severity: WidgetSeverity,
    priority: WidgetPriority,
    text: String
) -> WidgetSnapshot {
    WidgetSnapshot(
        descriptor: descriptor,
        generatedAt: Date(timeIntervalSince1970: 0),
        severity: severity,
        priority: priority,
        representations: .init(
            compact: .init(text: text, accessibilityLabel: text),
            normal: .init(text: text, accessibilityLabel: text)
        )
    )
}
