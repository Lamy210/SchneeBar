import Foundation
import SchneeBarCompanionCore
import Testing

@Test func hostGateAndIndependentOptInFailClosed() throws {
    var policy = CompanionHostPolicy()
    var inputs = CompanionHostPolicy.Inputs()
    inputs.preferences.enabled = true
    inputs.preferences.allowLocalEvents = true
    inputs.ownsMenuSurface = true
    inputs.catalogueRevision = UUID()
    let blocked = policy.reconcile(inputs)
    #expect(blocked.availability == .releaseBlocked)
    #expect(blocked.assetSession == nil)
    #expect(!blocked.wantsHostCPU && !blocked.listensToLocalEvents && !blocked.rendersCharacter)
    inputs.releaseApproved = true
    inputs.preferences.enabled = false
    #expect(policy.reconcile(inputs).availability == .disabled)
    inputs.preferences.enabled = true
    let active = policy.reconcile(inputs)
    #expect(active.rendersCharacter && active.wantsHostCPU && active.listensToLocalEvents)
    inputs.releaseApproved = false
    #expect(policy.reconcile(inputs).assetSession == nil)
}

@Test func hostSettingsRoundTripNeverPersistApprovalOrImplicitlyOptIn() throws {
    let defaults = CompanionHostPreferences()
    #expect(!defaults.enabled && !defaults.allowLocalEvents)
    let data = try JSONEncoder().encode(defaults)
    #expect(try JSONDecoder().decode(CompanionHostPreferences.self, from: data) == defaults)
    #expect(!String(decoding: data, as: UTF8.self).contains("releaseApproved"))
    var policy = CompanionHostPolicy()
    var input = CompanionHostPolicy.Inputs(preferences: defaults, releaseApproved: true,
        ownsMenuSurface: true, catalogueRevision: UUID())
    for preset in CompanionPresentationPreset.allCases {
        input.preferences.preset = preset
        let decision = policy.reconcile(input)
        #expect(decision.availability == .disabled)
        #expect(!decision.listensToLocalEvents && !decision.wantsHostCPU)
    }
}

@Test func hostAssetSessionFencesHideSleepOwnershipAndGateRevocation() throws {
    var policy = CompanionHostPolicy()
    var inputs = CompanionHostPolicy.Inputs(preferences: .init(enabled: true),
        releaseApproved: true, ownsMenuSurface: true)
    let initial = policy.reconcile(inputs)
    #expect(initial.availability == .awaitingCatalogue && !initial.wantsHostCPU)
    let first = try #require(initial.assetSession)
    #expect(policy.acceptsAssetResult(session: first))
    inputs.catalogueRevision = UUID()
    #expect(policy.reconcile(inputs).assetSession == first)
    inputs.preferences.speed = .double
    #expect(policy.reconcile(inputs).assetSession == first)
    #expect(policy.decision.mode == .manual(.double))
    inputs.preferences.preset = .minimal
    #expect(policy.reconcile(inputs).availability == .hidden)
    #expect(!policy.acceptsAssetResult(session: first))
    inputs.preferences.preset = .companion
    let second = try #require(policy.reconcile(inputs).assetSession)
    #expect(second != first)
    inputs.awake = false
    #expect(policy.reconcile(inputs).availability == .asleep)
    #expect(!policy.acceptsAssetResult(session: second))
    inputs.awake = true
    let third = try #require(policy.reconcile(inputs).assetSession)
    inputs.ownsMenuSurface = false
    #expect(policy.reconcile(inputs).availability == .surfaceUnavailable)
    #expect(!policy.acceptsAssetResult(session: third))
    inputs.ownsMenuSurface = true
    let fourth = try #require(policy.reconcile(inputs).assetSession)
    inputs.releaseApproved = false
    #expect(policy.reconcile(inputs).availability == .releaseBlocked)
    #expect(!policy.acceptsAssetResult(session: fourth))
}

@Test func hostMotionAndSpeedSuppressOnlyAutomaticDemand() throws {
    var policy = CompanionHostPolicy()
    var inputs = CompanionHostPolicy.Inputs(preferences: .init(enabled: true),
        releaseApproved: true, ownsMenuSurface: true, catalogueRevision: UUID())
    #expect(policy.reconcile(inputs).wantsHostCPU)
    #expect(!policy.decision.listensToLocalEvents)
    inputs.preferences.allowLocalEvents = true
    inputs.systemReduceMotion = true
    let reduced = policy.reconcile(inputs)
    #expect(reduced.rendersCharacter && reduced.reduceMotion && reduced.listensToLocalEvents)
    #expect(!reduced.wantsHostCPU && reduced.mode == .disabled)
    inputs.systemReduceMotion = false
    inputs.preferences.freeze = true
    #expect(!policy.reconcile(inputs).wantsHostCPU)
    inputs.preferences.freeze = false
    inputs.preferences.speed = .half
    #expect(policy.reconcile(inputs).mode == .manual(.half))
    #expect(!policy.decision.wantsHostCPU)
    inputs.preferences.speed = .automatic
    inputs.preferences.allowLocalEvents = false
    #expect(policy.reconcile(inputs).wantsHostCPU)
    #expect(!policy.decision.listensToLocalEvents)
}
