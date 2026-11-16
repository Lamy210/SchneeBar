import Foundation

/// The composition root owns one sampler and at most one lease per consumer.
public enum HostCPUConsumer: Hashable, Sendable {
    case widget, companion
}

public struct HostCPUConsumerLease: Equatable, Sendable {
    public let consumer: HostCPUConsumer
    fileprivate let token: UUID

    init(consumer: HostCPUConsumer) {
        self.consumer = consumer
        token = UUID()
    }
}

public struct HostCPUSample: Equatable, Sendable {
    public let id: UUID
    public let epoch: UUID
    public let capturedAt: ContinuousClock.Instant
    public let wallTime: Date
    public let percentage: Double
}

/// Demand-driven, monotonic five-second acquisition window. No autonomous timer.
/// Consumers must poll from their existing lifecycle, and fence presentation
/// with their own runtime generation after asynchronous calls.
public actor HostCPUSampler {
    private struct Flight {
        let id: UUID
        let task: Task<HostCPUSample, Error>
    }

    private struct Cached {
        let at: ContinuousClock.Instant
        let result: Result<HostCPUSample, Error>
    }

    private let readCounters: @Sendable () throws -> CPUCounters
    private let bootstrapDelay: @Sendable () async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onJoinInFlight: (@Sendable () -> Void)?
    private var previous: (counters: CPUCounters, instant: ContinuousClock.Instant)?
    private var cached: Cached?
    private var inFlight: Flight?
    private var leases: [HostCPUConsumer: HostCPUConsumerLease] = [:]
    private var epoch = UUID()
    private var suspended = false

    public init() {
        readCounters = readCPUCounters
        bootstrapDelay = { try await Task.sleep(for: .milliseconds(500)) }
        now = { ContinuousClock.now }
        onJoinInFlight = nil
    }

    init(
        readCounters: @escaping @Sendable () throws -> CPUCounters,
        bootstrapDelay: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        onJoinInFlight: (@Sendable () -> Void)? = nil,
        initialLease: HostCPUConsumerLease? = nil
    ) {
        self.readCounters = readCounters
        self.bootstrapDelay = bootstrapDelay
        self.now = now
        self.onJoinInFlight = onJoinInFlight
        if let initialLease { leases[initialLease.consumer] = initialLease }
    }

    public func subscribe(_ consumer: HostCPUConsumer) -> HostCPUConsumerLease {
        if let current = leases[consumer] { return current }
        let lease = HostCPUConsumerLease(consumer: consumer)
        leases[consumer] = lease
        return lease
    }

    public func unsubscribe(_ lease: HostCPUConsumerLease) {
        guard leases[lease.consumer] == lease else { return }
        leases.removeValue(forKey: lease.consumer)
        if leases.isEmpty { invalidate() }
    }

    public func suspend() {
        guard !suspended else { return }
        suspended = true
        invalidate()
    }

    public func resume() {
        guard suspended else { return }
        suspended = false
    }

    /// Atomic demand reconciliation for the single application composition owner.
    /// Calls must be serialized by that owner; do not mix with ad-hoc leases.
    public func reconcileDemand(widget: Bool, companion: Bool, sleeping: Bool) {
        if sleeping {
            suspend()
            leases.removeAll()
            return
        }
        resume()
        let desired: Set<HostCPUConsumer> = Set(
            (widget ? [.widget] : []) + (companion ? [.companion] : [])
        )
        let hadDemand = !leases.isEmpty
        for consumer in [HostCPUConsumer.widget, .companion] {
            if desired.contains(consumer) {
                _ = subscribe(consumer)
            } else {
                leases.removeValue(forKey: consumer)
            }
        }
        if hadDemand && leases.isEmpty { invalidate() }
    }

    /// Resolve the active lease at request entry; retain that lease across suspension.
    public func sample(for consumer: HostCPUConsumer) async throws -> HostCPUSample {
        guard let lease = leases[consumer] else { throw CancellationError() }
        return try await sample(for: lease)
    }

    public func sample(for lease: HostCPUConsumerLease) async throws -> HostCPUSample {
        try Task.checkCancellation()
        guard !suspended, leases[lease.consumer] == lease else {
            throw CancellationError()
        }
        let requestEpoch = epoch
        if let cached {
            let age = cached.at.duration(to: now())
            if age >= .zero && age < .seconds(5) {
                return try cached.result.get()
            }
        }

        let flight: Flight
        if let inFlight {
            onJoinInFlight?()
            flight = inFlight
        } else {
            let id = UUID()
            let task = Task { try await measure(epoch: requestEpoch, id: id) }
            flight = Flight(id: id, task: task)
            inFlight = flight
        }

        let result = await flight.task.result
        guard epoch == requestEpoch, !suspended else { throw CancellationError() }
        // Any waiter may finalize only its own current flight. An obsolete
        // waiter must not remove a replacement flight or rewrite its cache.
        if inFlight?.id == flight.id {
            inFlight = nil
            let capturedAt: ContinuousClock.Instant
            switch result {
            case let .success(sample): capturedAt = sample.capturedAt
            case .failure: capturedAt = now()
            }
            cached = Cached(at: capturedAt, result: result)
        }
        try Task.checkCancellation()
        guard leases[lease.consumer] == lease else { throw CancellationError() }
        return try result.get()
    }

    private func invalidate() {
        epoch = UUID()
        inFlight?.task.cancel()
        inFlight = nil
        cached = nil
        previous = nil
    }

    private func requireCurrent(_ requestEpoch: UUID) throws {
        try Task.checkCancellation()
        guard requestEpoch == epoch, !suspended, !leases.isEmpty else {
            throw CancellationError()
        }
    }

    private func measure(epoch requestEpoch: UUID, id: UUID) async throws -> HostCPUSample {
        try requireCurrent(requestEpoch)
        let first = try readCounters()
        let firstInstant = now()

        if let previous {
            let elapsed = previous.instant.duration(to: firstInstant)
            if elapsed > .zero && elapsed <= .seconds(30) {
                self.previous = (first, firstInstant)
                let percentage = try first.usagePercentage(since: previous.counters)
                return makeSample(id: id, epoch: requestEpoch, at: firstInstant, percentage: percentage)
            }
        }

        try await bootstrapDelay()
        // Even a non-cooperative delay cannot commit data after invalidation.
        try requireCurrent(requestEpoch)
        let second = try readCounters()
        let secondInstant = now()
        previous = (second, secondInstant)
        let percentage = try second.usagePercentage(since: first)
        return makeSample(id: id, epoch: requestEpoch, at: secondInstant, percentage: percentage)
    }

    private func makeSample(
        id: UUID, epoch: UUID, at instant: ContinuousClock.Instant, percentage: Double
    ) -> HostCPUSample {
        HostCPUSample(id: id, epoch: epoch, capturedAt: instant, wallTime: .now, percentage: percentage)
    }
}
