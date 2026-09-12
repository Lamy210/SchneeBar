import Darwin
import Foundation
import SchneeBarCore

public struct ClockWidgetProvider: WidgetProvider {
    public let descriptor = WidgetDescriptor(
        id: "system.clock",
        displayName: "Clock",
        defaultOrder: 200,
        defaultRepresentation: .compact,
        visibilityPolicy: .always,
        refreshPolicy: .interval(30)
    )

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    public func snapshot() async throws -> WidgetSnapshot {
        let date = now()
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let value = formatter.string(from: date)

        let content = WidgetContent(
            text: value,
            systemImage: "clock",
            accessibilityLabel: "Current time \(value)"
        )

        return WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: date,
            severity: .nominal,
            priority: .background,
            representations: .init(
                compact: content,
                normal: WidgetContent(
                    text: "Time \(value)",
                    systemImage: "clock",
                    accessibilityLabel: "Current time \(value)"
                )
            )
        )
    }
}

public actor CPUWidgetProvider: WidgetProvider {
    public nonisolated let descriptor = WidgetDescriptor(
        id: "system.cpu",
        displayName: "CPU",
        defaultOrder: 100,
        defaultRepresentation: .normal,
        visibilityPolicy: .always,
        refreshPolicy: .interval(5)
    )

    private var previous: CPUCounters?

    public init() {}

    public func snapshot() async throws -> WidgetSnapshot {
        var current = try readCPUCounters()
        let baseline: CPUCounters

        if let previous {
            baseline = previous
        } else {
            baseline = current
            try await Task.sleep(for: .milliseconds(120))
            current = try readCPUCounters()
        }

        previous = current

        let totalDelta = current.total >= baseline.total ? current.total - baseline.total : 0
        let activeDelta = current.active >= baseline.active ? current.active - baseline.active : 0
        let percentage = totalDelta == 0
            ? 0
            : min(100, max(0, Double(activeDelta) / Double(totalDelta) * 100))
        let rounded = Int(percentage.rounded())

        let severity: WidgetSeverity
        let priority: WidgetPriority
        switch percentage {
        case 95...:
            severity = .critical
            priority = .critical
        case 85...:
            severity = .attention
            priority = .attention
        default:
            severity = .nominal
            priority = .normal
        }

        let compact = WidgetContent(
            text: "\(rounded)%",
            systemImage: "cpu",
            accessibilityLabel: "CPU usage \(rounded) percent"
        )
        let normal = WidgetContent(
            text: "CPU \(rounded)%",
            systemImage: "cpu",
            accessibilityLabel: "CPU usage \(rounded) percent"
        )

        return WidgetSnapshot(
            descriptor: descriptor,
            severity: severity,
            priority: priority,
            representations: .init(
                compact: compact,
                normal: normal,
                critical: WidgetContent(
                    text: "CPU \(rounded)%",
                    systemImage: "exclamationmark.triangle.fill",
                    accessibilityLabel: "High CPU usage \(rounded) percent"
                )
            )
        )
    }
}

private struct CPUCounters {
    let active: UInt64
    let total: UInt64
}

private enum CPUWidgetError: Error {
    case hostStatistics(kern_return_t)
}

private func readCPUCounters() throws -> CPUCounters {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
    )

    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
        }
    }

    guard result == KERN_SUCCESS else {
        throw CPUWidgetError.hostStatistics(result)
    }

    let user = UInt64(info.cpu_ticks.0)
    let system = UInt64(info.cpu_ticks.1)
    let idle = UInt64(info.cpu_ticks.2)
    let nice = UInt64(info.cpu_ticks.3)
    let active = user + system + nice

    return CPUCounters(active: active, total: active + idle)
}
