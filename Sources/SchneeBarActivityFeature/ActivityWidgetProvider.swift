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

    private let loadSnapshot:
        @Sendable () async throws -> ActivityAggregateSnapshot

    public init(
        loadSnapshot:
            @escaping @Sendable () async throws -> ActivityAggregateSnapshot
    ) {
        self.loadSnapshot = loadSnapshot
    }

    public init(
        loadItems: @escaping @Sendable () async throws -> [ActivityItem]
    ) {
        loadSnapshot = {
            ActivityAggregateSnapshot(
                items: try await loadItems(),
                sources: []
            )
        }
    }

    public func snapshot() async throws -> WidgetSnapshot {
        let aggregate = try await loadSnapshot()
        let summary = ActivitySummary(items: aggregate.items)

        let severity: WidgetSeverity
        let priority: WidgetPriority
        if summary.needsAttention > 0 || summary.failed > 0 {
            severity = .critical
            priority = .critical
        } else if summary.actionRequired > 0 {
            severity = .attention
            priority = .attention
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
        if summary.actionRequired > 0 {
            compactText = "!\(summary.actionRequired)"
        } else if summary.needsAttention > 0 {
            compactText = "✕\(summary.needsAttention)"
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
