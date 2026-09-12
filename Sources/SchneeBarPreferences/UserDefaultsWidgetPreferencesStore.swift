import Foundation
import SchneeBarCore

public actor UserDefaultsWidgetPreferencesStore: WidgetPreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    public init(
        suiteName: String? = nil,
        key: String = "dev.lamy.schneebar.widget-configuration"
    ) {
        if let suiteName, let suiteDefaults = UserDefaults(suiteName: suiteName) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
        self.key = key
    }

    public func load() async throws -> WidgetConfiguration {
        guard let data = defaults.data(forKey: key) else {
            return WidgetConfiguration()
        }

        let decoder = JSONDecoder()
        do {
            let payload = try decoder.decode(PersistedWidgetConfiguration.self, from: data)
            guard payload.schemaVersion == PersistedWidgetConfiguration.currentSchemaVersion else {
                throw StoreError.unsupportedSchemaVersion(payload.schemaVersion)
            }
            return payload.configuration
        } catch let payloadError {
            // Development builds before the versioned envelope persisted the
            // configuration directly. Keep this one-way migration so early
            // adopters do not lose their local preferences.
            if let legacyConfiguration = try? decoder.decode(WidgetConfiguration.self, from: data) {
                return legacyConfiguration
            }
            throw payloadError
        }
    }

    public func save(_ configuration: WidgetConfiguration) async throws {
        let payload = PersistedWidgetConfiguration(
            schemaVersion: PersistedWidgetConfiguration.currentSchemaVersion,
            configuration: configuration
        )
        let data = try JSONEncoder().encode(payload)
        defaults.set(data, forKey: key)
    }
}

private struct PersistedWidgetConfiguration: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let configuration: WidgetConfiguration
}

private enum StoreError: Error {
    case unsupportedSchemaVersion(Int)
}
