import Foundation
import SchneeBarCore

public enum WidgetFixtureScenario: String, CaseIterable, Identifiable, Sendable {
    case nominal
    case attention
    case critical
    case manyWidgets

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nominal: "Nominal"
        case .attention: "Attention"
        case .critical: "Critical"
        case .manyWidgets: "Many Widgets"
        }
    }

    public var snapshots: [WidgetSnapshot] {
        switch self {
        case .nominal:
            [
                snapshot(
                    id: "system.cpu",
                    name: "CPU",
                    text: "CPU 24%",
                    severity: .nominal,
                    priority: .normal,
                    systemImage: "cpu"
                ),
                snapshot(
                    id: "system.clock",
                    name: "Clock",
                    text: "21:30",
                    severity: .nominal,
                    priority: .background,
                    systemImage: "clock"
                ),
            ]
        case .attention:
            [
                snapshot(
                    id: "developer.activity",
                    name: "Developer Activity",
                    text: "CI ●2",
                    severity: .active,
                    priority: .attention,
                    systemImage: "hammer"
                ),
                snapshot(
                    id: "system.cpu",
                    name: "CPU",
                    text: "CPU 88%",
                    severity: .attention,
                    priority: .attention,
                    systemImage: "cpu"
                ),
                snapshot(
                    id: "system.clock",
                    name: "Clock",
                    text: "21:30",
                    severity: .nominal,
                    priority: .background,
                    systemImage: "clock"
                ),
            ]
        case .critical:
            [
                snapshot(
                    id: "developer.activity",
                    name: "Developer Activity",
                    text: "CI ✕1",
                    severity: .critical,
                    priority: .critical,
                    systemImage: "exclamationmark.triangle.fill"
                ),
                snapshot(
                    id: "system.cpu",
                    name: "CPU",
                    text: "CPU 97%",
                    severity: .critical,
                    priority: .critical,
                    systemImage: "exclamationmark.triangle.fill"
                ),
                snapshot(
                    id: "system.clock",
                    name: "Clock",
                    text: "21:30",
                    severity: .nominal,
                    priority: .background,
                    systemImage: "clock"
                ),
            ]
        case .manyWidgets:
            [
                snapshot(id: "developer.activity", name: "Developer Activity", text: "CI ●3", severity: .active, priority: .attention, systemImage: "hammer"),
                snapshot(id: "system.cpu", name: "CPU", text: "CPU 54%", severity: .nominal, priority: .normal, systemImage: "cpu"),
                snapshot(id: "system.memory", name: "Memory", text: "RAM 68%", severity: .nominal, priority: .normal, systemImage: "memorychip"),
                snapshot(id: "system.network", name: "Network", text: "12 MB/s", severity: .nominal, priority: .normal, systemImage: "network"),
                snapshot(id: "system.battery", name: "Battery", text: "73%", severity: .nominal, priority: .background, systemImage: "battery.75percent"),
                snapshot(id: "system.clock", name: "Clock", text: "21:30", severity: .nominal, priority: .background, systemImage: "clock"),
            ]
        }
    }

    private func snapshot(
        id: WidgetID,
        name: String,
        text: String,
        severity: WidgetSeverity,
        priority: WidgetPriority,
        systemImage: String
    ) -> WidgetSnapshot {
        let descriptor = WidgetDescriptor(
            id: id,
            displayName: name,
            defaultRepresentation: .normal,
            visibilityPolicy: .always,
            refreshPolicy: .manual
        )

        let content = WidgetContent(
            text: text,
            systemImage: systemImage,
            accessibilityLabel: "\(name), \(text)"
        )

        return WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            severity: severity,
            priority: priority,
            representations: .init(compact: content, normal: content, critical: content)
        )
    }
}
