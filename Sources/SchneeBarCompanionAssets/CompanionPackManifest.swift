import Foundation
import SchneeBarCompanionCore

public enum CompanionPackError: Error, Equatable {
    case invalidManifest, unsupportedVersion, invalidName, invalidClips
    case unsafePath, invalidDirectory, openFailed, unsafeResource
}

/// Lexically validated relative path. Do not use a URL join to acquire it:
/// the descriptor reader must walk each component without following links.
public struct CompanionPackPath: Hashable, Sendable {
    public let components: [String]

    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CompanionPackError.unsafePath }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 16,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  $0.utf8.count <= 255 }) else { throw CompanionPackError.unsafePath }
        components = parts.map(String.init)
    }
}

/// Runner v1 wire schema, validated independently. Recognizing a kind is not
/// a claim that its animation decoder has already been implemented.
public struct CompanionPackManifest: Sendable {
    public enum Kind: String, Decodable, Sendable {
        case singleImage, spriteSheet4x2, pngSequence, gif, apng, webP
    }

    public struct Clip: Sendable {
        public let state: CompanionState
        public let kind: Kind
        public let path: CompanionPackPath
    }

    private struct Wire: Decodable {
        struct Entry: Decodable {
            let state: String
            let kind: Kind
            let path: String
        }
        let formatVersion: Int
        let name: String
        let defaultState: String
        let clips: [Entry]
    }

    public static let maximumBytes = 64 * 1024
    public static let filename = "character.json"
    public let name: String
    public let defaultState: CompanionState
    public let clips: [Clip]

    public static func decode(_ data: Data) throws -> Self {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes,
              !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { throw CompanionPackError.invalidManifest }
        guard wire.formatVersion == 1 else { throw CompanionPackError.unsupportedVersion }
        guard !wire.name.isEmpty, wire.name.count <= 80, wire.name.utf8.count <= 1024,
              wire.name == wire.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !wire.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CompanionPackError.invalidName }
        guard (1...5).contains(wire.clips.count), let fallback = state(wire.defaultState)
        else { throw CompanionPackError.invalidClips }
        var seen = Set<CompanionState>()
        var result: [Clip] = []
        for entry in wire.clips {
            guard let state = state(entry.state), seen.insert(state).inserted
            else { throw CompanionPackError.invalidClips }
            result.append(Clip(state: state, kind: entry.kind, path: try CompanionPackPath(entry.path)))
        }
        guard seen.contains(fallback) else { throw CompanionPackError.invalidClips }
        try Task.checkCancellation()
        return Self(name: wire.name, defaultState: fallback, clips: result)
    }

    private static func state(_ value: String) -> CompanionState? {
        switch value {
        case "idle": .idle
        case "walk": .walk
        case "run": .run
        case "dash": .dash
        case "sprint": .sprint
        default: nil
        }
    }
}
