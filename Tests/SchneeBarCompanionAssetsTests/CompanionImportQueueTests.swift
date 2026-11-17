import Foundation
import SchneeBarCompanionAssets
import Testing

private enum QueueFixtureError: Error, Equatable { case failed, timedOut }

/// Simulates a non-cooperative synchronous decoder. The bounded semaphore
/// avoids hanging CI if a regression prevents the gate from being released.
private final class QueueWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var inputs: [Int] = []
    private var active = 0
    private var peak = 0

    func run(_ input: Int) throws -> Int {
        lock.lock()
        inputs.append(input)
        active += 1
        peak = max(peak, active)
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }
        if input == 1, gate.wait(timeout: .now() + 5) != .success {
            throw QueueFixtureError.timedOut
        }
        if input == 4 { throw QueueFixtureError.failed }
        return input * 10
    }

    func release() { gate.signal() }
    func startedInputs() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return inputs
    }
    func peakWorkers() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

@MainActor
private func waitForQueue(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw QueueFixtureError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func importQueueKeepsOnlyNewestPendingAndWaitsForWorkerExit() async throws {
    let probe = QueueWorkerProbe()
    defer { probe.release() }
    let queue = CompanionImportQueue<Int, Int>(work: { try probe.run($0) })
    var values: [Int] = []
    queue.submit(1) { _ in Issue.record("Superseded request published") }
    try await waitForQueue { probe.startedInputs() == [1] }
    queue.submit(2) { _ in Issue.record("Replaced pending request published") }
    queue.submit(3) { result in
        if case let .success(value) = result { values.append(value) }
        else { Issue.record("Latest request failed") }
    }
    #expect(queue.isBusy)
    #expect(probe.startedInputs() == [1])
    probe.release()
    try await waitForQueue { !queue.isBusy }
    #expect(values == [30])
    #expect(probe.startedInputs() == [1, 3])
    #expect(probe.peakWorkers() == 1)
}

@Test @MainActor func importQueueCancelSuppressesCallbacksButRetainsWorkerSlot() async throws {
    let probe = QueueWorkerProbe()
    defer { probe.release() }
    let queue = CompanionImportQueue<Int, Int>(work: { try probe.run($0) })
    var values: [Int] = []
    queue.submit(1) { _ in Issue.record("Cancelled request published") }
    try await waitForQueue { probe.startedInputs() == [1] }
    queue.submit(2) { _ in Issue.record("Cancelled pending request published") }
    queue.cancel()
    #expect(queue.isBusy)
    queue.submit(3) { result in
        if case let .success(value) = result { values.append(value) }
        else { Issue.record("Replacement request failed") }
    }
    #expect(probe.startedInputs() == [1])
    probe.release()
    try await waitForQueue { !queue.isBusy }
    #expect(values == [30])
    #expect(probe.startedInputs() == [1, 3])
    #expect(probe.peakWorkers() == 1)
}

@Test @MainActor func importQueueLatestFailureDoesNotPublishStaleSuccessAndCanRetry() async throws {
    let probe = QueueWorkerProbe()
    let queue = CompanionImportQueue<Int, Int>(work: { try probe.run($0) })
    var failure: QueueFixtureError?
    queue.submit(4) { result in
        if case let .failure(error) = result { failure = error as? QueueFixtureError }
    }
    try await waitForQueue { !queue.isBusy }
    #expect(failure == .failed)
    var value: Int?
    queue.submit(3) { result in value = try? result.get() }
    try await waitForQueue { !queue.isBusy }
    #expect(value == 30)
}
