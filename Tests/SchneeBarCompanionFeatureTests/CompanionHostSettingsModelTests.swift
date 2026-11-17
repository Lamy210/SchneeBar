import Foundation
import SchneeBarCompanionCore
import SchneeBarCompanionFeature
import Testing

@MainActor
@Test func hostEditorDraftDiscardAndExplicitSave() throws {
    let name = "SchneeBarTests.hostEditor.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let model = CompanionHostSettingsModel(store: store)
    #expect(!model.canSave && !model.requiresRecovery)
    model.draft.enabled = true
    model.draft.allowLocalEvents = true
    #expect(model.canSave)
    #expect(store.load() == .missing)
    #expect(!model.committedPreferences.enabled)
    model.discardEdits()
    #expect(!model.hasChanges && !model.draft.enabled)
    model.draft.enabled = true
    model.draft.preset = .minimal
    model.save()
    #expect(model.notice == .saved && !model.hasChanges)
    #expect(store.load() == .valid(model.draft))
    var policy = CompanionHostPolicy()
    #expect(policy.reconcile(.init(preferences: model.committedPreferences)).availability == .releaseBlocked)
}

@MainActor
@Test func hostEditorDoesNotOverwriteChangedSettings() throws {
    let name = "SchneeBarTests.hostEditor.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let model = CompanionHostSettingsModel(store: store)
    model.draft.enabled = true
    let external = CompanionHostPreferences(speed: .double)
    try store.save(external)
    model.save()
    #expect(model.notice == .changedExternally)
    #expect(model.draft == external && !model.hasChanges)
    #expect(store.load() == .valid(external))
}

@MainActor
@Test func hostEditorResetRequiresCurrentConfirmationAndRecovery() throws {
    let name = "SchneeBarTests.hostEditor.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let key = CompanionHostPreferenceStore.storageKey
    defaults.set("invalid", forKey: key)
    defaults.set("keep", forKey: "other")
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let model = CompanionHostSettingsModel(store: store)
    #expect(model.requiresRecovery && !model.canSave)
    model.draft.enabled = true
    model.save()
    #expect(defaults.string(forKey: key) == "invalid")
    model.requestReset()
    let first = try #require(model.resetConfirmation)
    model.cancelReset()
    model.confirmReset(first)
    #expect(store.load() == .invalid)
    model.requestReset()
    let second = try #require(model.resetConfirmation)
    model.confirmReset(first)
    #expect(model.resetConfirmation == second)
    model.confirmReset(second)
    #expect(model.notice == .reset && !model.requiresRecovery)
    #expect(!model.draft.enabled && store.load() == .missing)
    #expect(defaults.string(forKey: "other") == "keep")
    model.requestReset()
    #expect(model.resetConfirmation == nil)
}

@MainActor
@Test func hostEditorRecoveryRechecksChangedRecord() throws {
    let name = "SchneeBarTests.hostEditor.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let key = CompanionHostPreferenceStore.storageKey
    defaults.set("invalid", forKey: key)
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let model = CompanionHostSettingsModel(store: store)
    model.requestReset()
    let token = try #require(model.resetConfirmation)
    let future = Data(#"{"version":2}"#.utf8)
    defaults.set(future, forKey: key)
    model.confirmReset(token)
    #expect(model.notice == .changedExternally)
    #expect(model.baseline == .unsupportedVersion(2))
    #expect(defaults.data(forKey: key) == future)
    #expect(model.resetConfirmation == nil)
}
