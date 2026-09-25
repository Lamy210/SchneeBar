import Foundation
import SchneeBarCore
import SchneeBarExternalWidgets
import Testing
@testable import SchneeBar

private actor StartupCoordinatorPreferencesStore: WidgetPreferencesStore {
    func load() async throws -> WidgetConfiguration {
        WidgetConfiguration()
    }

    func save(_ configuration: WidgetConfiguration) async throws {}
}

private actor StartupCoordinatorCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private actor StartupCoordinatorGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started {
            return
        }

        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum StartupCoordinatorTestError: Error {
    case failed
}

@Test @MainActor
func startupCoordinatorRunsSuccessfulRegistrationOnlyOnce() async throws {
    let counter = StartupCoordinatorCallCounter()
    let definition = coordinatorExternalWidgetDefinition()
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { engine in
            await counter.increment()
            let registrar = ExternalWidgetStartupRegistrar(
                loadDefinitions: { [definition] }
            )
            return try await registrar.loadAndRegister(in: engine)
        }
    )
    let model = coordinatorRuntimeModel()
    let engine = WidgetEngine()

    try await coordinator.runIfNeeded(
        in: engine,
        model: model,
        isCurrent: { true }
    )
    try await coordinator.runIfNeeded(
        in: engine,
        model: model,
        isCurrent: { true }
    )

    #expect(await counter.value() == 1)
    #expect(coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loaded(widgetCount: 1))
    #expect(
        await engine.descriptors().map(\.id)
            == [definition.descriptor.id]
    )

    coordinator.handleSleep(model: model)
    #expect(model.externalWidgetStartupHealth == .loaded(widgetCount: 1))
}

@Test @MainActor
func concurrentRunInSameGenerationDoesNotRegisterTwice() async throws {
    let counter = StartupCoordinatorCallCounter()
    let gate = StartupCoordinatorGate()
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            await counter.increment()
            await gate.waitUntilReleased()
            return .loaded(widgetCount: 1)
        }
    )
    let model = coordinatorRuntimeModel()
    let engine = WidgetEngine()

    let first = Task { @MainActor in
        try await coordinator.runIfNeeded(
            in: engine,
            model: model,
            isCurrent: { true }
        )
    }
    await gate.waitUntilStarted()

    try await coordinator.runIfNeeded(
        in: engine,
        model: model,
        isCurrent: { true }
    )

    #expect(await counter.value() == 1)

    await gate.release()
    try await first.value

    #expect(coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loaded(widgetCount: 1))
}

@Test @MainActor
func wakeRetryCanSupersedeCancellationInsensitiveStaleAttempt() async throws {
    let counter = StartupCoordinatorCallCounter()
    let firstAttemptGate = StartupCoordinatorGate()
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            let attempt = await counter.next()
            if attempt == 1 {
                await firstAttemptGate.waitUntilReleased()
                return .loaded(widgetCount: 1)
            }
            return .loaded(widgetCount: 2)
        }
    )
    let model = coordinatorRuntimeModel()
    let engine = WidgetEngine()

    let staleAttempt = Task { @MainActor in
        try await coordinator.runIfNeeded(
            in: engine,
            model: model,
            isCurrent: { true }
        )
    }
    await firstAttemptGate.waitUntilStarted()

    coordinator.handleSleep(model: model)
    #expect(model.externalWidgetStartupHealth == .notAttempted)

    try await coordinator.runIfNeeded(
        in: engine,
        model: model,
        isCurrent: { true }
    )

    #expect(await counter.value() == 2)
    #expect(coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loaded(widgetCount: 2))

    await firstAttemptGate.release()
    try await staleAttempt.value

    #expect(model.externalWidgetStartupHealth == .loaded(widgetCount: 2))
}

@Test @MainActor
func staleAttemptCleanupCannotClearNewActiveAttempt() async throws {
    let counter = StartupCoordinatorCallCounter()
    let firstGate = StartupCoordinatorGate()
    let secondGate = StartupCoordinatorGate()
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            let attempt = await counter.next()
            switch attempt {
            case 1:
                await firstGate.waitUntilReleased()
                return .loaded(widgetCount: 1)
            case 2:
                await secondGate.waitUntilReleased()
                return .loaded(widgetCount: 2)
            default:
                Issue.record("Unexpected third startup registration")
                return .loaded(widgetCount: 3)
            }
        }
    )
    let model = coordinatorRuntimeModel()
    let engine = WidgetEngine()

    let staleAttempt = Task { @MainActor in
        try await coordinator.runIfNeeded(
            in: engine,
            model: model,
            isCurrent: { true }
        )
    }
    await firstGate.waitUntilStarted()

    coordinator.handleSleep(model: model)

    let currentAttempt = Task { @MainActor in
        try await coordinator.runIfNeeded(
            in: engine,
            model: model,
            isCurrent: { true }
        )
    }
    await secondGate.waitUntilStarted()

    await firstGate.release()
    try await staleAttempt.value

    try await coordinator.runIfNeeded(
        in: engine,
        model: model,
        isCurrent: { true }
    )
    #expect(await counter.value() == 2)

    await secondGate.release()
    try await currentAttempt.value

    #expect(coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loaded(widgetCount: 2))
}

@Test @MainActor
func startupCoordinatorPreservesCancellationAndAllowsWakeRetry() async {
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            throw CancellationError()
        }
    )
    let model = coordinatorRuntimeModel()

    await #expect(throws: CancellationError.self) {
        try await coordinator.runIfNeeded(
            in: WidgetEngine(),
            model: model,
            isCurrent: { true }
        )
    }

    #expect(!coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loading)

    coordinator.handleSleep(model: model)
    #expect(model.externalWidgetStartupHealth == .notAttempted)
}

@Test @MainActor
func cancellationWinsOverConcurrentUnknownStartupFailure() async {
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            throw StartupCoordinatorTestError.failed
        }
    )
    let model = coordinatorRuntimeModel()

    await #expect(throws: CancellationError.self) {
        try await coordinator.runIfNeeded(
            in: WidgetEngine(),
            model: model,
            isCurrent: { true }
        )
    }

    #expect(!coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loading)
}

@Test @MainActor
func staleStartupCompletionCannotPublishTerminalHealthOrFinish() async throws {
    let gate = StartupCoordinatorGate()
    var isCurrent = true
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            await gate.waitUntilReleased()
            return .loaded(widgetCount: 2)
        }
    )
    let model = coordinatorRuntimeModel()

    let task = Task { @MainActor in
        try await coordinator.runIfNeeded(
            in: WidgetEngine(),
            model: model,
            isCurrent: { isCurrent }
        )
    }

    await gate.waitUntilStarted()
    isCurrent = false
    await gate.release()
    try await task.value

    #expect(!coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .loading)

    coordinator.handleSleep(model: model)
    #expect(model.externalWidgetStartupHealth == .notAttempted)
}

@Test @MainActor
func unknownThrownStartupFailureIsSanitizedAndTerminal() async throws {
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            throw StartupCoordinatorTestError.failed
        }
    )
    let model = coordinatorRuntimeModel()

    try await coordinator.runIfNeeded(
        in: WidgetEngine(),
        model: model,
        isCurrent: { true }
    )

    #expect(coordinator.isFinished)
    #expect(
        model.externalWidgetStartupHealth
            == .unavailable(.unknown)
    )

    coordinator.handleSleep(model: model)
    #expect(
        model.externalWidgetStartupHealth
            == .unavailable(.unknown)
    )
}

@Test @MainActor
func coordinatorDoesNothingWhenRuntimeIsAlreadyStale() async throws {
    let counter = StartupCoordinatorCallCounter()
    let coordinator = ExternalWidgetStartupCoordinator(
        register: { _ in
            await counter.increment()
            return .loaded(widgetCount: 1)
        }
    )
    let model = coordinatorRuntimeModel()

    try await coordinator.runIfNeeded(
        in: WidgetEngine(),
        model: model,
        isCurrent: { false }
    )

    #expect(await counter.value() == 0)
    #expect(!coordinator.isFinished)
    #expect(model.externalWidgetStartupHealth == .notAttempted)
}

@MainActor
private func coordinatorRuntimeModel() -> WidgetRuntimeModel {
    WidgetRuntimeModel(
        preferencesStore: StartupCoordinatorPreferencesStore()
    )
}

private func coordinatorExternalWidgetDefinition() -> ExternalWidgetDefinition {
    let descriptor = WidgetDescriptor(
        id: "external.integration.build",
        displayName: "Integration Build",
        defaultIsEnabled: false,
        defaultOrder: 1_200,
        refreshPolicy: .manual
    )
    return ExternalWidgetDefinition(
        descriptor: descriptor,
        snapshot: WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 123),
            severity: .nominal,
            priority: .normal,
            representations: WidgetRepresentations(
                compact: WidgetContent(
                    text: "OK",
                    accessibilityLabel: "Integration build okay"
                ),
                normal: WidgetContent(
                    text: "Integration build okay",
                    accessibilityLabel: "Integration build okay"
                )
            )
        )
    )
}
