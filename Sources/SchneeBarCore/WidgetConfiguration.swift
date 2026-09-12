public struct WidgetPreference: Codable, Equatable, Identifiable, Sendable {
    public let id: WidgetID
    public var isEnabled: Bool
    public var order: Int
    public var representation: WidgetRepresentationKind?

    public init(
        id: WidgetID,
        isEnabled: Bool,
        order: Int,
        representation: WidgetRepresentationKind? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.order = order
        self.representation = representation
    }
}

public struct WidgetConfiguration: Codable, Equatable, Sendable {
    public var preferences: [WidgetPreference]

    public init(preferences: [WidgetPreference] = []) {
        self.preferences = preferences
    }

    public func preference(for id: WidgetID) -> WidgetPreference? {
        preferences.first(where: { $0.id == id })
    }

    public func isEnabled(_ descriptor: WidgetDescriptor) -> Bool {
        preference(for: descriptor.id)?.isEnabled ?? descriptor.defaultIsEnabled
    }

    public func order(for descriptor: WidgetDescriptor) -> Int {
        preference(for: descriptor.id)?.order ?? descriptor.defaultOrder
    }

    public func representation(for snapshot: WidgetSnapshot) -> WidgetRepresentationKind {
        if snapshot.severity >= .critical {
            return .critical
        }

        return preference(for: snapshot.descriptor.id)?.representation
            ?? snapshot.descriptor.defaultRepresentation
    }

    public mutating func setEnabled(_ isEnabled: Bool, for descriptor: WidgetDescriptor) {
        updatePreference(for: descriptor) { preference in
            preference.isEnabled = isEnabled
        }
    }

    public mutating func setRepresentation(
        _ representation: WidgetRepresentationKind?,
        for descriptor: WidgetDescriptor
    ) {
        updatePreference(for: descriptor) { preference in
            preference.representation = representation
        }
    }

    public mutating func setOrder(_ order: Int, for descriptor: WidgetDescriptor) {
        updatePreference(for: descriptor) { preference in
            preference.order = order
        }
    }

    private mutating func updatePreference(
        for descriptor: WidgetDescriptor,
        update: (inout WidgetPreference) -> Void
    ) {
        if let index = preferences.firstIndex(where: { $0.id == descriptor.id }) {
            update(&preferences[index])
            return
        }

        var preference = WidgetPreference(
            id: descriptor.id,
            isEnabled: descriptor.defaultIsEnabled,
            order: descriptor.defaultOrder,
            representation: nil
        )
        update(&preference)
        preferences.append(preference)
    }
}

public protocol WidgetPreferencesStore: Sendable {
    func load() async throws -> WidgetConfiguration
    func save(_ configuration: WidgetConfiguration) async throws
}
