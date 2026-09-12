import Foundation
import SchneeBarCore
import Testing

private actor PreferenceCountingProvider: WidgetProvider {
    nonisolated let descriptor: WidgetDescriptor
    private let priority: WidgetPriority
    private var calls = 0

    init(
        id: WidgetID,
        order: Int,
        defaultIsEnabled: Bool = true,
        priority: WidgetPriority = .normal
    ) {
        descriptor = WidgetDescriptor(
            id: id,
            displayName: id.rawValue,
            defaultIsEnabled: defaultIsEnabled,
            defaultOrder: order,
            visibilityPolicy: .always,
            refreshPolicy: .interval(10)
        )
        self.priority = priority
    }

    func snapshot() async throws -> WidgetSnapshot {
        calls += 1
        return WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 0),
            severity: priority == .critical ? .critical : .nominal,
            priority: priority,
            representations: .init(
                compact: .init(text: descriptor.id.rawValue, accessibilityLabel: descriptor.id.rawValue),
                normal: .init(text: descriptor.id.rawValue, accessibilityLabel: descriptor.id.rawValue)
            )
        )
    }

    func callCount() -> Int {
        calls
    }
}

@Test
func disabledWidgetsAreNotRefreshedOrDisplayed() async {
    let enabled = PreferenceCountingProvider(id: "enabled", order: 0)
    let disabled = PreferenceCountingProvider(id: "disabled", order: 1)
    var configuration = WidgetConfiguration()
    configuration.setEnabled(false, for: disabled.descriptor)

    let engine = WidgetEngine(
        providers: [enabled, disabled],
        configuration: configuration
    )

    let snapshots = await engine.refreshDue(at: Date(timeIntervalSince1970: 1_000))

    #expect(await enabled.callCount() == 1)
    #expect(await disabled.callCount() == 0)
    #expect(snapshots.map(\.descriptor.id.rawValue) == ["enabled"])
}

@Test
func defaultDisabledWidgetsDoNotRefreshUntilExplicitlyEnabled() async {
    let provider = PreferenceCountingProvider(
        id: "opt-in",
        order: 0,
        defaultIsEnabled: false
    )
    let engine = WidgetEngine(providers: [provider])
    let start = Date(timeIntervalSince1970: 2_000)

    _ = await engine.refreshDue(at: start)
    #expect(await provider.callCount() == 0)

    var configuration = WidgetConfiguration()
    configuration.setEnabled(true, for: provider.descriptor)
    await engine.setConfiguration(configuration)

    let snapshots = await engine.refreshDue(at: start)
    #expect(await provider.callCount() == 1)
    #expect(snapshots.map(\.descriptor.id.rawValue) == ["opt-in"])
}

@Test
func reenabledWidgetRefreshesImmediatelyEvenInsidePreviousInterval() async {
    let provider = PreferenceCountingProvider(id: "reenabled", order: 0)
    let engine = WidgetEngine(providers: [provider])
    let firstAttempt = Date(timeIntervalSince1970: 3_000)

    _ = await engine.refreshDue(at: firstAttempt)
    #expect(await provider.callCount() == 1)

    var disabledConfiguration = WidgetConfiguration()
    disabledConfiguration.setEnabled(false, for: provider.descriptor)
    await engine.setConfiguration(disabledConfiguration)

    var enabledConfiguration = disabledConfiguration
    enabledConfiguration.setEnabled(true, for: provider.descriptor)
    await engine.setConfiguration(enabledConfiguration)

    _ = await engine.refreshDue(at: firstAttempt.addingTimeInterval(1))
    #expect(await provider.callCount() == 2)
}

@Test
func userOrderAppliesWithinSamePriority() async {
    let first = PreferenceCountingProvider(id: "first", order: 0)
    let second = PreferenceCountingProvider(id: "second", order: 100)
    var configuration = WidgetConfiguration()
    configuration.setOrder(200, for: first.descriptor)
    configuration.setOrder(10, for: second.descriptor)

    let engine = WidgetEngine(
        providers: [first, second],
        configuration: configuration
    )

    let snapshots = await engine.refreshAll(at: Date(timeIntervalSince1970: 1_000))

    #expect(snapshots.map(\.descriptor.id.rawValue) == ["second", "first"])
}

@Test
func criticalPriorityOverridesManualOrder() async {
    let normal = PreferenceCountingProvider(id: "normal", order: 0)
    let critical = PreferenceCountingProvider(id: "critical", order: 100, priority: .critical)
    var configuration = WidgetConfiguration()
    configuration.setOrder(0, for: normal.descriptor)
    configuration.setOrder(999, for: critical.descriptor)

    let engine = WidgetEngine(
        providers: [normal, critical],
        configuration: configuration
    )

    let snapshots = await engine.refreshAll(at: Date(timeIntervalSince1970: 1_000))

    #expect(snapshots.map(\.descriptor.id.rawValue) == ["critical", "normal"])
}

@Test
func applyingConfigurationDisablesAlreadyCachedWidgetImmediately() async {
    let provider = PreferenceCountingProvider(id: "cached", order: 0)
    let engine = WidgetEngine(providers: [provider])

    _ = await engine.refreshAll(at: Date(timeIntervalSince1970: 1_000))
    #expect((await engine.orderedVisibleSnapshots()).count == 1)

    var configuration = WidgetConfiguration()
    configuration.setEnabled(false, for: provider.descriptor)
    await engine.setConfiguration(configuration)

    #expect((await engine.orderedVisibleSnapshots()).isEmpty)
}
