import Foundation
import SchneeBarCompanionCore

/// Local user intent only. This adapter is not wired to the shipping app.
/// One main-actor owner must use the injected domain; no default registration,
/// cross-process transactions, runtime approval or credential storage.
@MainActor
public final class CompanionHostPreferenceStore {
    public static let storageKey = "SchneeBar.companion.hostPreferences"
    private static let currentVersion = 1
    private static let maximumRecordBytes = 4096

    public enum ReadResult: Equatable, Sendable {
        case missing
        case valid(CompanionHostPreferences)
        case invalid
        case unsupportedVersion(Int)

        /// Consumers may use these safe defaults, but must not implicitly save
        /// them over an unreadable record.
        public var preferences: CompanionHostPreferences {
            if case .valid(let value) = self { return value }
            return .init()
        }
    }

    /// Internal comparison only; raw malformed content is never surfaced in UI.
    struct Snapshot {
        enum Identity: Equatable {
            case missing, data(Data), propertyList(Data), unavailable
        }
        let result: ReadResult
        let identity: Identity

        func matches(_ other: Snapshot) -> Bool {
            identity != .unavailable && identity == other.identity && result == other.result
        }
    }

    public enum WriteError: Error, Equatable, Sendable {
        case invalidExistingRecord
        case unsupportedExistingVersion(Int)
        case recordTooLarge
    }

    private struct Header: Decodable {
        let version: Int
    }

    private struct Record: Codable {
        let version: Int
        let preferences: CompanionHostPreferences
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> ReadResult {
        decode(defaults.object(forKey: Self.storageKey))
    }

    /// Decode and capture identity from the same read. Data is compared byte
    /// for byte, other supported property-list values by serialized content.
    /// Serialization failure must never authorize an overwrite or reset.
    func snapshot() -> Snapshot {
        let object = defaults.object(forKey: Self.storageKey)
        let identity: Snapshot.Identity
        if let object {
            if let data = object as? Data {
                identity = .data(data)
            } else if let encoded = try? PropertyListSerialization.data(
                fromPropertyList: ["record": object], format: .binary, options: 0
            ) {
                identity = .propertyList(encoded)
            } else {
                identity = .unavailable
            }
        } else {
            identity = .missing
        }
        return Snapshot(result: decode(object), identity: identity)
    }

    private func decode(_ object: Any?) -> ReadResult {
        guard let object else {
            return .missing
        }
        guard let data = object as? Data,
              !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            return .invalid
        }
        let decoder = JSONDecoder()
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == Self.currentVersion else {
                return .unsupportedVersion(header.version)
            }
            let record = try decoder.decode(Record.self, from: data)
            return .valid(record.preferences)
        } catch {
            return .invalid
        }
    }

    /// Save only on explicit user intent; preserve invalid/future data until
    /// a separate confirmed reset. No write on startup or decode failure.
    public func save(_ preferences: CompanionHostPreferences) throws {
        switch load() {
        case .missing, .valid:
            break
        case .invalid:
            throw WriteError.invalidExistingRecord
        case .unsupportedVersion(let version):
            throw WriteError.unsupportedExistingVersion(version)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Record(version: Self.currentVersion, preferences: preferences))
        guard data.count <= Self.maximumRecordBytes else {
            throw WriteError.recordTooLarge
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// The caller must obtain explicit destructive-reset confirmation.
    /// Only this key is removed; other preferences are never touched.
    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
