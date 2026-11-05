import Darwin
import Foundation
import SchneeBarCore

public struct ClockWidgetProvider: WidgetProvider {
    public let descriptor = WidgetDescriptor(
        id: "system.clock",
        displayName: "Clock",
        defaultIsEnabled: false,
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

/// Whole-machine CPU activity; unlike Activity Monitor's per-process % CPU,
/// 100% means all of the host's CPU time is busy.
public actor CPUWidgetProvider: WidgetProvider {
    public nonisolated let descriptor = WidgetDescriptor(
        id: "system.cpu",
        displayName: "Total CPU",
        defaultIsEnabled: true,
        defaultOrder: 100,
        defaultRepresentation: .normal,
        visibilityPolicy: .always,
        refreshPolicy: .interval(5)
    )

    private var previous: (counters: CPUCounters, instant: ContinuousClock.Instant)?
    private var inFlight: Task<Double, Error>?
    private let readCounters: @Sendable () throws -> CPUCounters
    private let bootstrapDelay: @Sendable () async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    public init() {
        readCounters = readCPUCounters
        bootstrapDelay = { try await Task.sleep(for: .milliseconds(500)) }
        now = { ContinuousClock.now }
    }

    /// Internal injection seams let tests verify exact deltas and overlapping
    /// initial snapshots without depending on the host's current CPU load.
    init(
        readCounters: @escaping @Sendable () throws -> CPUCounters,
        bootstrapDelay: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.readCounters = readCounters
        self.bootstrapDelay = bootstrapDelay
        self.now = now
    }

    public func snapshot() async throws -> WidgetSnapshot {
        // WidgetEngine may request another refresh while the first bootstrap
        // sleep is suspended. Share that measurement instead of racing baselines.
        let percentage: Double
        if let inFlight {
            percentage = try await inFlight.value
        } else {
            let task = Task { try await measurePercentage() }
            inFlight = task
            defer { inFlight = nil }
            percentage = try await task.value
        }

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
            accessibilityLabel: "Total CPU usage \(rounded) percent"
        )
        let normal = WidgetContent(
            text: "Total CPU \(rounded)%",
            systemImage: "cpu",
            accessibilityLabel: "Total CPU usage \(rounded) percent"
        )

        return WidgetSnapshot(
            descriptor: descriptor,
            severity: severity,
            priority: priority,
            representations: .init(
                compact: compact,
                normal: normal,
                critical: WidgetContent(
                    text: "Total CPU \(rounded)%",
                    systemImage: "exclamationmark.triangle.fill",
                    accessibilityLabel: "High total CPU usage \(rounded) percent"
                )
            )
        )
    }

    private func measurePercentage() async throws -> Double {
        let first = try readCounters()
        let firstInstant = now()

        if let previous {
            let elapsed = previous.instant.duration(to: firstInstant)
            // Discard a stale baseline after sleep/wake or a long suspension.
            // A fresh short interval is preferable to a misleading average.
            if elapsed > .zero && elapsed <= .seconds(30) {
                self.previous = (first, firstInstant)
                return try first.usagePercentage(since: previous.counters)
            }
        }

        try await bootstrapDelay()
        try Task.checkCancellation()
        let second = try readCounters()
        previous = (second, now())
        return try second.usagePercentage(since: first)
    }
}

/// host_cpu_load_info_data_t uses natural_t (32-bit) *per CPU state*.
/// Widening already-summed counters before subtraction loses wrap information;
/// subtract each state with modulo-2^32 arithmetic, then widen and aggregate.
struct CPUCounters: Sendable, Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func usagePercentage(since previous: CPUCounters) throws -> Double {
        let userDelta = UInt64(user &- previous.user)
        let systemDelta = UInt64(system &- previous.system)
        let niceDelta = UInt64(nice &- previous.nice)
        let idleDelta = UInt64(idle &- previous.idle)

        let activeDelta = userDelta + systemDelta + niceDelta
        let totalDelta = activeDelta + idleDelta
        guard totalDelta > 0 else {
            // Lack of fresh host ticks is not evidence of a genuinely idle CPU.
            throw CPUWidgetError.noCounterProgress
        }
        return Double(activeDelta) / Double(totalDelta) * 100
    }
}

enum CPUWidgetError: Error, Equatable {
    case hostStatistics(kern_return_t)
    case noCounterProgress
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

    return CPUCounters(
        user: UInt32(truncatingIfNeeded: info.cpu_ticks.0),
        system: UInt32(truncatingIfNeeded: info.cpu_ticks.1),
        idle: UInt32(truncatingIfNeeded: info.cpu_ticks.2),
        nice: UInt32(truncatingIfNeeded: info.cpu_ticks.3)
    )
}
