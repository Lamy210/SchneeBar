import SchneeBarCore

public enum WidgetSettingsFixture {
    public static let descriptors: [WidgetDescriptor] = [
        WidgetDescriptor(
            id: "developer.activity",
            displayName: "Developer Activity",
            defaultOrder: 0,
            defaultRepresentation: .normal,
            visibilityPolicy: .whenNotNominal,
            refreshPolicy: .adaptive(active: 20, idle: 180)
        ),
        WidgetDescriptor(
            id: "system.cpu",
            displayName: "CPU",
            defaultOrder: 100,
            defaultRepresentation: .normal,
            visibilityPolicy: .always,
            refreshPolicy: .interval(5)
        ),
        WidgetDescriptor(
            id: "system.clock",
            displayName: "Clock",
            defaultOrder: 200,
            defaultRepresentation: .compact,
            visibilityPolicy: .always,
            refreshPolicy: .interval(30)
        ),
    ]

    public static let configured = WidgetConfiguration(
        preferences: [
            WidgetPreference(
                id: "developer.activity",
                isEnabled: true,
                order: 0,
                representation: .compact
            ),
            WidgetPreference(
                id: "system.cpu",
                isEnabled: false,
                order: 100,
                representation: .normal
            ),
            WidgetPreference(
                id: "system.clock",
                isEnabled: true,
                order: 200,
                representation: nil
            ),
        ]
    )
}
