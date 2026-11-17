import Foundation

/// Latest-only publication with at most one active synchronous worker and one
/// pending input. Cancellation is advisory: a replacement does not start until
/// even a non-cooperative earlier worker has actually returned.
@MainActor
public final class CompanionImportQueue<Input: Sendable, Output: Sendable> {
    private struct Job {
        let id: UUID
        let input: Input
    }

    private struct Flight {
        let id: UUID
        let worker: Task<Output, Error>
    }

    private let work: @Sendable (Input) throws -> Output
    private var active: Flight?
    private var pending: Job?
    private var latest: UUID?
    private var completion: (@MainActor (Result<Output, Error>) -> Void)?

    public init(work: @escaping @Sendable (Input) throws -> Output) {
        self.work = work
    }

    /// True until the active worker actually exits, including after cancel().
    public var isBusy: Bool { active != nil }

    /// Superseded requests receive no callback. Only the latest request can
    /// publish success or error on the main actor. Owners must capture weakly
    /// in the callback if they retain the queue.
    public func submit(
        _ input: Input, completion: @escaping @MainActor (Result<Output, Error>) -> Void
    ) {
        let job = Job(id: UUID(), input: input)
        latest = job.id
        self.completion = completion
        if let active {
            pending = job
            active.worker.cancel()
        } else {
            start(job)
        }
    }

    /// Suppress pending and active results immediately, but do not free the
    /// worker slot until the active synchronous operation has returned.
    public func cancel() {
        latest = nil
        pending = nil
        completion = nil
        active?.worker.cancel()
    }

    deinit { active?.worker.cancel() }

    private func start(_ job: Job) {
        let input = job.input
        let id = job.id
        let work = work
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try work(input)
            try Task.checkCancellation()
            return value
        }
        active = Flight(id: id, worker: worker)
        Task { @MainActor [weak self] in
            let result = await worker.result
            self?.finish(id, result: result)
        }
    }

    private func finish(_ id: UUID, result: Result<Output, Error>) {
        guard active?.id == id else { return }
        active = nil
        if latest == id {
            latest = nil
            let callback = completion
            completion = nil
            callback?(result)
        } else if let pending {
            self.pending = nil
            start(pending)
        }
    }
}
