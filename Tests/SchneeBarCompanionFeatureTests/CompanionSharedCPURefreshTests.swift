import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
@testable import SchneeBarCompanionFeature
import Testing

@MainActor
private func cpuRefreshRuntime() throws -> CompanionRuntimeCoordinator {
    let data = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    let clip = try CompanionImageDecoder.decode(data)
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {}))
    runtime.setCatalog(try CompanionAssetCatalog(assets: [.run: clip], defaultState: .run))
    return runtime
}

@Test @MainActor func sharedCPURefreshSkipsInactiveManualAndReducedMotion() async throws {
    let runtime = try cpuRefreshRuntime()
    var reads = 0
    let refresh = CompanionSharedCPURefresh(runtime: runtime, read: {
        reads += 1
        return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
    })
    await refresh.refresh(isCurrent: { true })
    #expect(reads == 0)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    runtime.setMode(.manual(.half))
    await refresh.refresh(isCurrent: { true })
    #expect(reads == 0 && runtime.rate == .half)
    runtime.setMode(.automatic)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: true)
    await refresh.refresh(isCurrent: { true })
    #expect(reads == 0)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    await refresh.refresh(isCurrent: { false })
    #expect(reads == 0)
    await refresh.refresh(isCurrent: { true })
    #expect(reads == 1 && runtime.rate == .double)
    runtime.setPresentation(enabled: false, visible: false, awake: true, reduceMotion: false)
}

@Test @MainActor func sharedCPURefreshFailureClearsReactionButCancellationDoesNot() async throws {
    struct Failure: Error {}
    let runtime = try cpuRefreshRuntime()
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    defer { runtime.setPresentation(enabled: false, visible: false, awake: true, reduceMotion: false) }
    var calls = 0
    let refresh = CompanionSharedCPURefresh(runtime: runtime, read: {
        calls += 1
        if calls == 2 { throw CancellationError() }
        if calls == 3 { throw Failure() }
        return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
    })
    await refresh.refresh(isCurrent: { true })
    #expect(runtime.rate == .double)
    await refresh.refresh(isCurrent: { true })
    #expect(runtime.rate == .double)
    await refresh.refresh(isCurrent: { true })
    #expect(runtime.rate == .normal)
}

@Test @MainActor func sharedCPURefreshFencesGenerationAndExplicitInvalidation() async throws {
    let runtime = try cpuRefreshRuntime()
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    defer { runtime.setPresentation(enabled: false, visible: false, awake: true, reduceMotion: false) }
    var current = true
    let stale = CompanionSharedCPURefresh(runtime: runtime, read: {
        await Task.yield()
        current = false
        return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
    })
    await stale.refresh(isCurrent: { current })
    #expect(runtime.rate == .normal)

    var invalidate: (@MainActor () -> Void)?
    let refresh = CompanionSharedCPURefresh(runtime: runtime, read: {
        await Task.yield()
        invalidate?()
        return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
    })
    invalidate = { [weak refresh] in refresh?.invalidate() }
    await refresh.refresh(isCurrent: { true })
    #expect(runtime.rate == .normal)
    invalidate = nil
    await refresh.refresh(isCurrent: { true })
    #expect(runtime.rate == .double)
}
