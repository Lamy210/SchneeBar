import Foundation
import SchneeBarCore
import Testing

private func emptyStateDescriptor(
    _ id: WidgetID,
    defaultIsEnabled: Bool = true,
    visibilityPolicy: WidgetVisibilityPolicy = .whenNotNominal
) -> WidgetDescriptor {
    WidgetDescriptor(
        id: id,
        displayName: id.rawValue,
        defaultIsEnabled: defaultIsEnabled,
        visibilityPolicy: visibilityPolicy,
        refreshPolicy: .interval(5)
    )
}

private func emptyStateDiagnostic(
    _ descriptor: WidgetDescriptor,
    health: WidgetRuntimeHealth,
    attempted: Bool = true
) -> WidgetRuntimeDiagnostic {
    WidgetRuntimeDiagnostic(
        descriptor: descriptor,
        health: health,
        lastAttemptedAt: attempted ? Date(timeIntervalSince1970: 100) : nil,
        lastSucceededAt: health == .healthy ? Date(timeIntervalSince1970: 100) : nil,
        lastFailureAt: health == .unavailable ? Date(timeIntervalSince1970: 100) : nil,
        consecutiveFailureCount: health == .unavailable ? 1 : 0,
        isServingLastKnownGood: false,
        snapshotGeneratedAt: nil
    )
}

@Test
func emptyWidgetsWithoutDescriptorsShowLoadingRatherThanDisabled() {
    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [],
        configuration: WidgetConfiguration(),
        diagnosticsByWidgetID: [:]
    ) == .awaitingWidgets)
}

@Test
func allDisabledWidgetsShowSettingsGuidance() {
    let cpu = emptyStateDescriptor("system.cpu")
    let clock = emptyStateDescriptor("system.clock", defaultIsEnabled: false)
    var config = WidgetConfiguration()
    config.setEnabled(false, for: cpu)

    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [cpu, clock],
        configuration: config,
        diagnosticsByWidgetID: [
            cpu.id: emptyStateDiagnostic(cpu, health: .unavailable),
        ]
    ) == .allDisabled)
}

@Test
func enabledWidgetsWithoutRuntimeDiagnosticsShowInitialLoading() {
    let cpu = emptyStateDescriptor("system.cpu")
    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [cpu],
        configuration: WidgetConfiguration(),
        diagnosticsByWidgetID: [:]
    ) == .awaitingFirstReading)
}

@Test
func enabledNotLoadedWidgetsShowWaitingForReadings() {
    let cpu = emptyStateDescriptor("system.cpu")
    let other = emptyStateDescriptor("developer.activity", defaultIsEnabled: false)
    let diagnostics = [
        cpu.id: emptyStateDiagnostic(cpu, health: .notLoaded, attempted: false),
        other.id: emptyStateDiagnostic(other, health: .healthy),
    ]

    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [cpu, other],
        configuration: WidgetConfiguration(),
        diagnosticsByWidgetID: diagnostics
    ) == .awaitingFirstReading)
}

@Test
func healthyWidgetsHiddenByPolicyHaveAccurateEmptyMessage() {
    let activity = emptyStateDescriptor("developer.activity")
    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [activity],
        configuration: WidgetConfiguration(),
        diagnosticsByWidgetID: [
            activity.id: emptyStateDiagnostic(activity, health: .healthy),
        ]
    ) == .hiddenByPolicy)
}

@Test
func staleDiagnosticForReplacedProviderDoesNotPretendWidgetLoaded() {
    let current = emptyStateDescriptor("system.cpu")
    let previous = emptyStateDescriptor("system.cpu", visibilityPolicy: .always)
    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [current],
        configuration: WidgetConfiguration(),
        diagnosticsByWidgetID: [
            current.id: emptyStateDiagnostic(previous, health: .healthy),
        ]
    ) == .awaitingFirstReading)
}

@Test
func allEnabledWidgetsLoadedOverridesDisabledOrHiddenState() {
    let hidden = emptyStateDescriptor("developer.activity")
    let loading = emptyStateDescriptor("system.cpu")
    #expect(WidgetEmptyDisplayReason.resolve(
        descriptors: [hidden, loading],
        configuration: WidgetConfiguration(),
        diagnosticsByWidgetID: [
            hidden.id: emptyStateDiagnostic(hidden, health: .healthy),
            loading.id: emptyStateDiagnostic(loading, health: .notLoaded, attempted: false),
        ]
    ) == .awaitingFirstReading)
}
