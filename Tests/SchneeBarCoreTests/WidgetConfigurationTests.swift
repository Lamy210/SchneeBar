import Foundation
import SchneeBarCore
import Testing

@Test
func widgetConfigurationUsesDescriptorDefaultsWithoutPreference() {
    let descriptor = WidgetDescriptor(
        id: "system.clock",
        displayName: "Clock",
        defaultOrder: 200,
        defaultRepresentation: .compact
    )
    let snapshot = makeConfigurationSnapshot(descriptor: descriptor, severity: .nominal)
    let configuration = WidgetConfiguration()

    #expect(configuration.isEnabled(descriptor.id))
    #expect(configuration.order(for: descriptor) == 200)
    #expect(configuration.representation(for: snapshot) == .compact)
}

@Test
func widgetConfigurationAllowsPerWidgetOverrides() {
    let descriptor = WidgetDescriptor(
        id: "system.cpu",
        displayName: "CPU",
        defaultOrder: 100,
        defaultRepresentation: .normal
    )
    let snapshot = makeConfigurationSnapshot(descriptor: descriptor, severity: .nominal)
    var configuration = WidgetConfiguration()

    configuration.setEnabled(false, for: descriptor)
    configuration.setOrder(7, for: descriptor)
    configuration.setRepresentation(.compact, for: descriptor)

    #expect(!configuration.isEnabled(descriptor.id))
    #expect(configuration.order(for: descriptor) == 7)
    #expect(configuration.representation(for: snapshot) == .compact)
}

@Test
func criticalSeverityAlwaysUsesCriticalRepresentation() {
    let descriptor = WidgetDescriptor(
        id: "developer.activity",
        displayName: "Developer Activity",
        defaultRepresentation: .normal
    )
    let snapshot = makeConfigurationSnapshot(descriptor: descriptor, severity: .critical)
    var configuration = WidgetConfiguration()
    configuration.setRepresentation(.compact, for: descriptor)

    #expect(configuration.representation(for: snapshot) == .critical)
}

private func makeConfigurationSnapshot(
    descriptor: WidgetDescriptor,
    severity: WidgetSeverity
) -> WidgetSnapshot {
    WidgetSnapshot(
        descriptor: descriptor,
        generatedAt: Date(timeIntervalSince1970: 0),
        severity: severity,
        priority: .normal,
        representations: .init(
            compact: .init(text: "C", accessibilityLabel: "Compact"),
            normal: .init(text: "N", accessibilityLabel: "Normal"),
            critical: .init(text: "X", accessibilityLabel: "Critical")
        )
    )
}
