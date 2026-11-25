import Foundation
import SchneeBarCompanionCore
import SchneeBarCompanionFeature
import Testing

@MainActor
@Test func hostStoreExplicitSaveRoundTripsAndResetIsScoped() throws {
    let name = "SchneeBarTests.hostPreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    #expect(store.load() == .missing)
    #expect(!store.load().preferences.enabled)
    #expect(defaults.object(forKey: CompanionHostPreferenceStore.storageKey) == nil)
    defaults.set("keep", forKey: "unrelated")
    let selected = CompanionHostPreferences(enabled: true, speed: .double,
        freeze: true, allowLocalEvents: true, preset: .minimal)
    try store.save(selected)
    let reopened = CompanionHostPreferenceStore(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(reopened.load() == .valid(selected))
    let data = try #require(defaults.data(forKey: CompanionHostPreferenceStore.storageKey))
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("releaseApproved"))
    #expect(!json.contains("ownsMenuSurface"))
    var policy = CompanionHostPolicy()
    #expect(policy.reconcile(.init(preferences: reopened.load().preferences)).availability == .releaseBlocked)
    try reopened.save(.init())
    #expect(store.load() == .valid(.init()))
    store.reset()
    #expect(store.load() == .missing)
    #expect(defaults.string(forKey: "unrelated") == "keep")
}

@MainActor
@Test func hostStoreMalformedRecordsFailClosedAndAreNotOverwritten() throws {
    let name = "SchneeBarTests.hostPreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let key = CompanionHostPreferenceStore.storageKey
    let invalid: [Data] = [
        Data(),
        Data(repeating: 0x20, count: 4097),
        Data("not json".utf8),
        Data(#"{"version":1,"preferences":{"enabled":true}}"#.utf8),
        Data(#"{"version":1,"preferences":{"enabled":true,"showMenuCharacter":true,"speed":"unknown","freeze":false,"allowLocalEvents":true,"preset":"dashboard"}}"#.utf8)
    ]
    for record in invalid {
        defaults.set(record, forKey: key)
        #expect(store.load() == .invalid)
        #expect(!store.load().preferences.enabled && !store.load().preferences.allowLocalEvents)
        #expect(throws: CompanionHostPreferenceStore.WriteError.invalidExistingRecord) {
            try store.save(.init(enabled: true))
        }
        #expect(defaults.data(forKey: key) == record)
    }
    defaults.set("wrong type", forKey: key)
    #expect(store.load() == .invalid)
    #expect(throws: CompanionHostPreferenceStore.WriteError.invalidExistingRecord) {
        try store.save(.init())
    }
    #expect(defaults.string(forKey: key) == "wrong type")
    store.reset()
    try store.save(.init(enabled: true))
    #expect(store.load() == .valid(.init(enabled: true)))
}

@MainActor
@Test func hostStoreFutureVersionIsPreservedUntilExplicitReset() throws {
    let name = "SchneeBarTests.hostPreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let key = CompanionHostPreferenceStore.storageKey
    let data = Data(#"{"version":2,"future":{"enable":true}}"#.utf8)
    defaults.set(data, forKey: key)
    #expect(store.load() == .unsupportedVersion(2))
    #expect(store.load().preferences == .init())
    #expect(throws: CompanionHostPreferenceStore.WriteError.unsupportedExistingVersion(2)) {
        try store.save(.init())
    }
    #expect(defaults.data(forKey: key) == data)
    store.reset()
    #expect(store.load() == .missing)
}

@MainActor
@Test func hostStoreUnknownApprovalFieldsNeverGrantRuntimeApproval() throws {
    let name = "SchneeBarTests.hostPreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let key = CompanionHostPreferenceStore.storageKey
    defaults.set(Data(#"{"version":1,"releaseApproved":true,"preferences":{"enabled":true,"showMenuCharacter":true,"speed":"automatic","freeze":false,"allowLocalEvents":true,"preset":"dashboard","ownsMenuSurface":true}}"#.utf8), forKey: key)
    let preferences = store.load().preferences
    #expect(preferences.enabled && preferences.allowLocalEvents)
    var policy = CompanionHostPolicy()
    let decision = policy.reconcile(.init(preferences: preferences, ownsMenuSurface: true, catalogueRevision: UUID()))
    #expect(decision.availability == .releaseBlocked)
    #expect(!decision.wantsHostCPU && !decision.listensToLocalEvents)
    try store.save(preferences)
    let saved = try #require(defaults.data(forKey: key))
    let json = String(decoding: saved, as: UTF8.self)
    #expect(!json.contains("releaseApproved") && !json.contains("ownsMenuSurface"))
}
