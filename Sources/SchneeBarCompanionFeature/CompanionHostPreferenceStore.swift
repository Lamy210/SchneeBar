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
        guard let object = defaults.object(forKey: Self.storageKey) else {
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
