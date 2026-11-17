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

    private let sampler: HostCPUSampler
    private let lease: HostCPUConsumerLease?

    public init() {
        let lease = HostCPUConsumerLease(consumer: .widget)
        self.lease = lease
        sampler = HostCPUSampler(
            readCounters: readCPUCounters,
            bootstrapDelay: { try await Task.sleep(for: .milliseconds(500)) },
            now: { ContinuousClock.now },
            initialLease: lease
        )
    }

    /// Managed mode: the app reconciles demand before asking the engine to refresh.
    public init(sampler: HostCPUSampler) {
        self.sampler = sampler
        lease = nil
    }

    /// The shared composition root passes its own widget lease.
    public init(sampler: HostCPUSampler, lease: HostCPUConsumerLease) {
        self.sampler = sampler
        self.lease = lease
    }

    init(
        readCounters: @escaping @Sendable () throws -> CPUCounters,
        bootstrapDelay: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        onJoinInFlight: (@Sendable () -> Void)? = nil
    ) {
        let lease = HostCPUConsumerLease(consumer: .widget)
        self.lease = lease
        sampler = HostCPUSampler(
            readCounters: readCounters,
            bootstrapDelay: bootstrapDelay,
            now: now,
            onJoinInFlight: onJoinInFlight,
            initialLease: lease
        )
    }

    public func snapshot() async throws -> WidgetSnapshot {
        let sample: HostCPUSample
        if let lease {
            sample = try await sampler.sample(for: lease)
        } else {
            sample = try await sampler.sample(for: .widget)
        }
        let percentage = sample.percentage
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
            generatedAt: sample.wallTime,
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

        // A true 32-bit wrap over an ordinary five-second window produces
        // a small modular delta. A huge modular delta is far more likely to
        // be a reset/discontinuity, so fail rather than invent CPU load.
        let largestDelta = max(userDelta, systemDelta, niceDelta, idleDelta)
        guard largestDelta <= UInt64(UInt32.max / 2) else {
            throw CPUWidgetError.implausibleCounterDelta
        }

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
    case implausibleCounterDelta
}

func readCPUCounters() throws -> CPUCounters {
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
