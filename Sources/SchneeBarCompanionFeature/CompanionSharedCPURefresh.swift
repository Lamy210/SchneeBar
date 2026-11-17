import Foundation
import SchneeBarSystemProvider

/// One-shot adapter for the existing host refresh loop. The composition
/// owner reconciles both sampler demands and wakes the loop; no timer,
/// subscription, or separate sampler is created here.
@MainActor
public final class CompanionSharedCPURefresh {
    struct Reading: Sendable {
        let id: UUID
        let epoch: UUID
        let capturedAt: ContinuousClock.Instant
        let percentage: Double
    }

    private let runtime: CompanionRuntimeCoordinator
    private let read: @MainActor () async throws -> Reading
    private var pending: UUID?

    public convenience init(runtime: CompanionRuntimeCoordinator, sampler: HostCPUSampler) {
        self.init(runtime: runtime, read: {
            let sample = try await sampler.sample(for: .companion)
            return Reading(id: sample.id, epoch: sample.epoch,
                capturedAt: sample.capturedAt, percentage: sample.percentage)
        })
    }

    init(runtime: CompanionRuntimeCoordinator, read: @escaping @MainActor () async throws -> Reading) {
        self.runtime = runtime
        self.read = read
    }

    /// Call before replacing a host lifecycle/configuration generation or
    /// companion lease. A non-cooperative old read cannot publish afterwards.
    public func invalidate() {
        pending = nil
        runtime.invalidateCPU()
    }

    /// Host calls this once per iteration even when the widget just acquired
    /// a cached sample. The shared sampler deduplicates physical acquisition;
    /// the runtime rejects duplicate/out-of-order samples.
    public func refresh(isCurrent: @MainActor () -> Bool) async {
        guard !Task.isCancelled, isCurrent(), pending == nil,
              let request = runtime.beginCPURequest() else { return }
        let token = UUID()
        pending = token
        defer { if pending == token { pending = nil } }

        do {
            let sample = try await read()
            guard pending == token, !Task.isCancelled, isCurrent(),
                  runtime.wantsHostCPU else { return }
            runtime.acceptCPU(request, id: sample.id, epoch: sample.epoch,
                capturedAt: sample.capturedAt, hostPercentage: sample.percentage)
        } catch is CancellationError {
            // Lease/generation cancellation is not a measurement failure.
        } catch {
            guard pending == token, !Task.isCancelled, isCurrent(),
                  runtime.wantsHostCPU else { return }
            runtime.cpuUnavailable(request)
        }
    }
}
