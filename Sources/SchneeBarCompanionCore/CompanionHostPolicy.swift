import Foundation

/// Presentation presets change layout only. No implicit feature enablement
/// or permission changes, and no coupling to GitHub authentication.
public enum CompanionPresentationPreset: String, Codable, CaseIterable, Sendable {
    case minimal, dashboard, companion
}

/// Independent user intent. The release/ownership gate is deliberately
/// absent from persistent settings and cannot be enabled by decoding them.
public struct CompanionHostPreferences: Codable, Equatable, Sendable {
    public enum Speed: String, Codable, CaseIterable, Sendable {
        case automatic, half, twoThirds, normal, oneAndHalf, double

        public var mode: CompanionCPUInput.Mode {
            switch self {
            case .automatic: .automatic
            case .half: .manual(.half)
            case .twoThirds: .manual(.twoThirds)
            case .normal: .manual(.normal)
            case .oneAndHalf: .manual(.oneAndHalf)
            case .double: .manual(.double)
            }
        }
    }

    public var enabled: Bool
    public var showMenuCharacter: Bool
    public var speed: Speed
    public var freeze: Bool
    public var allowLocalEvents: Bool
    public var preset: CompanionPresentationPreset

    public init(enabled: Bool = false, showMenuCharacter: Bool = true,
                speed: Speed = .automatic, freeze: Bool = false,
                allowLocalEvents: Bool = false, preset: CompanionPresentationPreset = .dashboard) {
        self.enabled = enabled
        self.showMenuCharacter = showMenuCharacter
        self.speed = speed
        self.freeze = freeze
        self.allowLocalEvents = allowLocalEvents
        self.preset = preset
    }
}

/// Pure host decision seam. The approved capability is supplied by the
/// composition root, not by user defaults, preset, events or asset data.
/// No production caller is wired in this slice.
public struct CompanionHostPolicy: Sendable {
    public enum Availability: Equatable, Sendable {
        case releaseBlocked, disabled, hidden, asleep, surfaceUnavailable, awaitingCatalogue, active
    }

    public struct Inputs: Equatable, Sendable {
        public var preferences: CompanionHostPreferences
        public var releaseApproved: Bool
        public var awake: Bool
        public var ownsMenuSurface: Bool
        public var systemReduceMotion: Bool
        public var catalogueRevision: UUID?

        public init(preferences: CompanionHostPreferences = .init(),
                    releaseApproved: Bool = false, awake: Bool = true,
                    ownsMenuSurface: Bool = false, systemReduceMotion: Bool = false,
                    catalogueRevision: UUID? = nil) {
            self.preferences = preferences
            self.releaseApproved = releaseApproved
            self.awake = awake
            self.ownsMenuSurface = ownsMenuSurface
            self.systemReduceMotion = systemReduceMotion
            self.catalogueRevision = catalogueRevision
        }
    }

    public struct Decision: Equatable, Sendable {
        public let availability: Availability
        public let assetSession: UUID?
        public let mode: CompanionCPUInput.Mode
        public let wantsHostCPU: Bool
        public let listensToLocalEvents: Bool
        public let reduceMotion: Bool

        public var rendersCharacter: Bool { availability == .active }
    }

    public private(set) var decision = Decision(availability: .releaseBlocked,
        assetSession: nil, mode: .disabled, wantsHostCPU: false,
        listensToLocalEvents: false, reduceMotion: false)

    public init() {}

    /// Sessions fence asynchronous catalogue acquisition. Hide, sleep, gate
    /// revocation and ownership loss invalidate the previous session; changing
    /// only the speed/preset does not supersede an unrelated asset request.
    @discardableResult
    public mutating func reconcile(_ inputs: Inputs) -> Decision {
        let prefs = inputs.preferences
        let availability: Availability
        if !inputs.releaseApproved { availability = .releaseBlocked }
        else if !prefs.enabled { availability = .disabled }
        else if !prefs.showMenuCharacter || prefs.preset == .minimal { availability = .hidden }
        else if !inputs.awake { availability = .asleep }
        else if !inputs.ownsMenuSurface { availability = .surfaceUnavailable }
        else if inputs.catalogueRevision == nil { availability = .awaitingCatalogue }
        else { availability = .active }

        let allowsAssets = availability == .active || availability == .awaitingCatalogue
        let active = availability == .active
        let motion = prefs.freeze || inputs.systemReduceMotion
        let session: UUID? = allowsAssets
            ? (decision.assetSession ?? UUID())
            : nil
        let mode = active && !motion ? prefs.speed.mode : .disabled
        decision = Decision(availability: availability, assetSession: session, mode: mode,
            wantsHostCPU: mode == .automatic,
            listensToLocalEvents: active && prefs.allowLocalEvents,
            reduceMotion: motion)
        return decision
    }

    public func acceptsAssetResult(session: UUID) -> Bool {
        decision.assetSession == session
    }
}
