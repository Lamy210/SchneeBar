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

@Test
func widgetVisibilityPoliciesUseSeverity() {
    #expect(WidgetVisibilityPolicy.always.isVisible(for: .nominal))
    #expect(!WidgetVisibilityPolicy.whenNotNominal.isVisible(for: .nominal))
    #expect(WidgetVisibilityPolicy.whenNotNominal.isVisible(for: .active))
    #expect(!WidgetVisibilityPolicy.minimumSeverity(.attention).isVisible(for: .active))
    #expect(WidgetVisibilityPolicy.minimumSeverity(.attention).isVisible(for: .critical))
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
