import Foundation
import SchneeBarCore
import SchneeBarPreferences
import Testing

@Test
func widgetPreferencesStoreReturnsEmptyConfigurationByDefault() async throws {
    let suite = "dev.lamy.schneebar.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = UserDefaultsWidgetPreferencesStore(suiteName: suite)
    let configuration = try await store.load()

    #expect(configuration == WidgetConfiguration())
}

@Test
func widgetPreferencesStoreRoundTripsConfiguration() async throws {
    let suite = "dev.lamy.schneebar.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = UserDefaultsWidgetPreferencesStore(suiteName: suite)
    let expected = WidgetConfiguration(
        preferences: [
            WidgetPreference(
                id: "system.cpu",
                isEnabled: false,
                order: 20,
                representation: .compact
            ),
            WidgetPreference(
                id: "system.clock",
                isEnabled: true,
                order: 10,
                representation: .normal
            ),
        ]
    )

    try await store.save(expected)
    let loaded = try await store.load()

    #expect(loaded == expected)
}

@Test
func widgetPreferencesStoreMigratesLegacyUnversionedConfiguration() async throws {
    let suite = "dev.lamy.schneebar.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let key = "legacy-widget-configuration"
    let expected = WidgetConfiguration(
        preferences: [
            WidgetPreference(
                id: "system.clock",
                isEnabled: true,
                order: 200,
                representation: .compact
            )
        ]
    )
    defaults.set(try JSONEncoder().encode(expected), forKey: key)

    let store = UserDefaultsWidgetPreferencesStore(
        suiteName: suite,
        key: key
    )
    let loaded = try await store.load()

    #expect(loaded == expected)
}


@Test
func widgetPreferencesStoreKeepsMalformedPersistedWidgetIDsReadable() async throws {
    let suite = "dev.lamy.schneebar.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let malformedID = WidgetID(rawValue: "../stale-widget")
    let store = UserDefaultsWidgetPreferencesStore(suiteName: suite)
    let expected = WidgetConfiguration(
        preferences: [
            WidgetPreference(
                id: malformedID,
                isEnabled: true,
                order: 1,
                representation: .compact
            ),
            WidgetPreference(
                id: "system.clock",
                isEnabled: false,
                order: 2,
                representation: .normal
            ),
        ]
    )

    try await store.save(expected)
    let loaded = try await store.load()

    #expect(loaded == expected)
    #expect(!malformedID.isValidProviderID)
    #expect(
        loaded.preference(for: "system.clock")?.isEnabled == false
    )
}

@Test
func legacyUnversionedMalformedWidgetIDRemainsReadable() async throws {
    let suite = "dev.lamy.schneebar.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let key = "legacy-malformed-widget-configuration"
    let malformedID = WidgetID(rawValue: "legacy/widget")
    let expected = WidgetConfiguration(
        preferences: [
            WidgetPreference(
                id: malformedID,
                isEnabled: true,
                order: 9
            ),
            WidgetPreference(
                id: "system.cpu",
                isEnabled: false,
                order: 10
            ),
        ]
    )
    defaults.set(try JSONEncoder().encode(expected), forKey: key)

    let store = UserDefaultsWidgetPreferencesStore(
        suiteName: suite,
        key: key
    )
    let loaded = try await store.load()

    #expect(loaded == expected)
    #expect(!malformedID.isValidProviderID)
    #expect(
        loaded.preference(for: "system.cpu")?.isEnabled == false
    )
}
