import SchneeBarCore
import Testing

@Test
func runtimeGenerationIsCurrentOnlyWhileAwake() throws {
    var lifecycle = WidgetRuntimeLifecycle()

    let generation = try #require(lifecycle.beginRuntime())

    #expect(!lifecycle.isSleeping)
    #expect(lifecycle.isCurrent(generation))

    lifecycle.willSleep()

    #expect(lifecycle.isSleeping)
    #expect(!lifecycle.isCurrent(generation))
}

@Test
func wakingCreatesANewCurrentGeneration() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let beforeSleep = try #require(lifecycle.beginRuntime())

    lifecycle.willSleep()
    let afterWake = try #require(lifecycle.didWake())

    #expect(!lifecycle.isSleeping)
    #expect(afterWake != beforeSleep)
    #expect(!lifecycle.isCurrent(beforeSleep))
    #expect(lifecycle.isCurrent(afterWake))
}

@Test
func duplicatePowerEventsAreIdempotent() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let initial = try #require(lifecycle.beginRuntime())

    lifecycle.willSleep()
    lifecycle.willSleep()

    #expect(lifecycle.isSleeping)
    #expect(!lifecycle.isCurrent(initial))

    let afterWake = try #require(lifecycle.didWake())
    #expect(lifecycle.didWake() == nil)
    #expect(lifecycle.isCurrent(afterWake))
}

@Test
func runtimeCannotBeginWhileSleeping() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let initial = try #require(lifecycle.beginRuntime())

    lifecycle.willSleep()

    #expect(lifecycle.beginRuntime() == nil)
    #expect(!lifecycle.isCurrent(initial))
}
