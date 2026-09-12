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
