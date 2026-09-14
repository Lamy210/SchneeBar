import SchneeBarCore
import Testing

@Test
func runtimeGenerationIsCurrentOnlyWhileAwake() throws {
    var lifecycle = WidgetRuntimeLifecycle()

    let generationCandidate = lifecycle.beginRuntime()
    let generation = try #require(generationCandidate)

    #expect(!lifecycle.isSleeping)
    #expect(lifecycle.isCurrent(generation))

    lifecycle.willSleep()

    #expect(lifecycle.isSleeping)
    #expect(!lifecycle.isCurrent(generation))
}

@Test
func wakingCreatesANewCurrentGeneration() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let beforeSleepCandidate = lifecycle.beginRuntime()
    let beforeSleep = try #require(beforeSleepCandidate)

    lifecycle.willSleep()
    let afterWakeCandidate = lifecycle.didWake()
    let afterWake = try #require(afterWakeCandidate)

    #expect(!lifecycle.isSleeping)
    #expect(afterWake != beforeSleep)
    #expect(!lifecycle.isCurrent(beforeSleep))
    #expect(lifecycle.isCurrent(afterWake))
}

@Test
func duplicatePowerEventsAreIdempotent() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let initialCandidate = lifecycle.beginRuntime()
    let initial = try #require(initialCandidate)

    lifecycle.willSleep()
    lifecycle.willSleep()

    #expect(lifecycle.isSleeping)
    #expect(!lifecycle.isCurrent(initial))

    let afterWakeCandidate = lifecycle.didWake()
    let afterWake = try #require(afterWakeCandidate)
    let duplicateWake = lifecycle.didWake()

    #expect(duplicateWake == nil)
    #expect(lifecycle.isCurrent(afterWake))
}

@Test
func runtimeCannotBeginWhileSleeping() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let initialCandidate = lifecycle.beginRuntime()
    let initial = try #require(initialCandidate)

    lifecycle.willSleep()
    let sleepingRuntime = lifecycle.beginRuntime()

    #expect(sleepingRuntime == nil)
    #expect(!lifecycle.isCurrent(initial))
}
