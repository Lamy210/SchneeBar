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
