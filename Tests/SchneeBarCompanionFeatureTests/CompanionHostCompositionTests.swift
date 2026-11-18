import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionEvents
@testable import SchneeBarCompanionFeature
import Testing

private enum HostCompositionFixtureError: Error { case timeout }

@MainActor
private func waitForHostComposition(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw HostCompositionFixtureError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func hostCompositionCatalogue() throws -> CompanionAssetCatalog {
    let bytes = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    let clip = try CompanionImageDecoder.decode(bytes)
    return try CompanionAssetCatalog(assets: [.run: clip], defaultState: .run)
}

@Test @MainActor func hostCompositionRoutesCommittedSettingsAndRevokesDemandOnSleep() async throws {
    let name = "SchneeBarTests.hostComposition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.title = "CPU 42%"
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let original = try #require(button.image)
    var demands: [CompanionHostComposition.Demand] = []
    var reads = 0
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: {
                reads += 1
                return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
            })
        },
        onDemandChanged: { demands.append($0) })
    defer { owner.stop() }
    let id = UUID()
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    owner.settings.draft.enabled = true
    owner.settings.draft.allowLocalEvents = true
    #expect(!owner.requestInstalledAsset(id))
    owner.settings.save()
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .loaded(id))
    #expect(owner.demand.cpu && owner.demand.localEventSession != nil)
    let firstSession = owner.demand.localEventSession
    #expect(button.image !== original && button.title == "CPU 42%")
    await owner.refreshCPU(isCurrent: { true })
    #expect(reads == 1)
    owner.settings.draft.freeze = true
    #expect(owner.demand.cpu)
    owner.settings.save()
    #expect(!owner.demand.cpu && owner.demand.localEventSession == firstSession)
    await owner.refreshCPU(isCurrent: { true })
    #expect(reads == 1)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(button.image === original && owner.demand.localEventSession == nil)
    #expect(owner.decision.availability == .asleep && !owner.isStopped)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.demand.localEventSession != nil && owner.demand.localEventSession != firstSession)
    owner.stop()
    #expect(owner.isStopped && button.image === original)
    #expect(demands.last?.cpu == false && demands.last?.localEventSession == nil)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!owner.requestInstalledAsset(id))
}

@Test @MainActor func hostCompositionExternalImageReplacementStopsWithoutClobbering() async throws {
    let name = "SchneeBarTests.hostComposition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: {
                Issue.record("Frozen owner must not acquire CPU")
                return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
            })
        })
    defer { owner.stop() }
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(UUID()))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.demand.localEventSession != nil)
    let external = NSImage(size: NSSize(width: 16, height: 16))
    button.image = external
    await owner.refreshCPU(isCurrent: { true })
    #expect(owner.isStopped && owner.demand.localEventSession == nil)
    #expect(button.image === external)
    #expect(owner.decision.availability == .releaseBlocked)
    #expect(!owner.requestInstalledAsset(UUID()))
}


@Test @MainActor func hostCompositionLocalEventsRequireCommittedOptInAndCurrentSession() async throws {
    let name = "SchneeBarTests.hostEvent.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() })
        })
    defer { owner.stop() }
    let id = UUID()
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    var evaluations = 0
    func payload() -> CompanionLocalEventIngress.Payload {
        evaluations += 1
        return .bytes(Data(#"{"phase":"started"}"#.utf8))
    }
    owner.settings.draft.allowLocalEvents = true
    #expect(owner.demand.localEventSession == nil)
    #expect(owner.receiveLocalEvent(session: UUID(), kind: .build, payload: payload) == nil)
    #expect(evaluations == 0)
    owner.settings.save()
    let first = try #require(owner.demand.localEventSession)
    #expect(owner.receiveLocalEvent(session: first, kind: .build, payload: payload) == .accepted)
    #expect(evaluations == 1)
    #expect(owner.receiveLocalEvent(session: first, kind: .build) { .oversized } == .oversized)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(owner.receiveLocalEvent(session: first, kind: .build, payload: payload) == nil)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    let second = try #require(owner.demand.localEventSession)
    #expect(second != first)
    #expect(owner.receiveLocalEvent(session: first, kind: .build, payload: payload) == nil)
    #expect(evaluations == 1)
    #expect(owner.receiveLocalEvent(session: second, kind: .build, payload: payload) == .accepted)
    owner.settings.draft.allowLocalEvents = false
    owner.settings.save()
    #expect(owner.receiveLocalEvent(session: second, kind: .build, payload: payload) == nil)
    #expect(evaluations == 2)
}

@Test @MainActor func hostCompositionEventChecksImageOwnershipBeforeParsing() async throws {
    let name = "SchneeBarTests.hostEvent.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() })
        })
    defer { owner.stop() }
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(UUID()))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    let session = try #require(owner.demand.localEventSession)
    let external = NSImage(size: NSSize(width: 16, height: 16))
    button.image = external
    #expect(owner.receiveLocalEvent(session: session, kind: .build) {
        Issue.record("Lost image owner evaluated payload")
        return .malformed
    } == nil)
    #expect(owner.isStopped && owner.demand.localEventSession == nil)
    #expect(button.image === external)
}
