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

        return try JSONDecoder().decode(WidgetConfiguration.self, from: data)
    }

    public func save(_ configuration: WidgetConfiguration) async throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: key)
    }
}
