import SchneeBarCore

public struct ActivityWidgetProvider: WidgetProvider {
    public let descriptor = WidgetDescriptor(
        id: "developer.activity",
        displayName: "Developer Activity",
        defaultOrder: 0,
        defaultRepresentation: .normal,
        visibilityPolicy: .whenNotNominal,
        refreshPolicy: .adaptive(active: 20, idle: 180)
    )

    private let loadItems: @Sendable () async throws -> [ActivityItem]

    public init(
        loadItems: @escaping @Sendable () async throws -> [ActivityItem]
    ) {
        self.loadItems = loadItems
    }

    public func snapshot() async throws -> WidgetSnapshot {
        let items = try await loadItems()
        let summary = ActivitySummary(items: items)

        let severity: WidgetSeverity
        let priority: WidgetPriority
        if summary.failed > 0 {
            severity = .critical
            priority = .critical
        } else if summary.running > 0 {
            severity = .active
            priority = .attention
        } else if summary.waiting > 0 {
            severity = .attention
            priority = .normal
        } else {
            severity = .nominal
            priority = .normal
        }

        let normalText = summary.menuBarLabel
        let compactText: String
        if summary.failed > 0 {
            compactText = "✕\(summary.failed)"
        } else if summary.running > 0 {
            compactText = "●\(summary.running)"
        } else if summary.waiting > 0 {
            compactText = "◷\(summary.waiting)"
        } else {
            compactText = "✓"
        }

        return WidgetSnapshot(
            descriptor: descriptor,
            severity: severity,
            priority: priority,
            representations: .init(
                compact: WidgetContent(
                    text: compactText,
                    systemImage: "hammer",
                    accessibilityLabel: normalText
                ),
                normal: WidgetContent(
                    text: normalText,
                    systemImage: "hammer",
                    accessibilityLabel: normalText
                ),
                critical: WidgetContent(
                    text: normalText,
                    systemImage: "exclamationmark.triangle.fill",
                    accessibilityLabel: normalText
                )
            )
        )
    }
}
