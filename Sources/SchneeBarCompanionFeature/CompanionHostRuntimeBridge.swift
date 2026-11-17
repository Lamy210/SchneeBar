import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore

/// Development-only integration seam. The composition root owns all platform
/// signals, asset acquisition, shared CPU scheduling and event transport.
@MainActor
public final class CompanionHostRuntimeBridge {
    public struct Environment: Equatable, Sendable {
        public var releaseApproved: Bool
        public var awake: Bool
        public var ownsMenuSurface: Bool
        public var systemReduceMotion: Bool

        public init(releaseApproved: Bool = false, awake: Bool = true,
                    ownsMenuSurface: Bool = false, systemReduceMotion: Bool = false) {
            self.releaseApproved = releaseApproved
            self.awake = awake
            self.ownsMenuSurface = ownsMenuSurface
            self.systemReduceMotion = systemReduceMotion
        }
    }

    public struct AssetRequest: Equatable, Sendable {
        fileprivate let session: UUID
        fileprivate let id: UUID
    }

    private let store: CompanionHostPreferenceStore
    private let runtime: CompanionRuntimeCoordinator
    private var policy = CompanionHostPolicy()
    private var environment = Environment()
    private var catalogue: CompanionAssetCatalog?
    private var catalogueRevision: UUID?
    private var pendingAsset: AssetRequest?

    public init(store: CompanionHostPreferenceStore, runtime: CompanionRuntimeCoordinator) {
        self.store = store
        self.runtime = runtime
        reconcile()
    }

    public var decision: CompanionHostPolicy.Decision { policy.decision }

    /// The caller must invoke this on platform lifecycle/ownership changes.
    public func updateEnvironment(_ next: Environment) {
        environment = next
        reconcile()
    }

    /// Call after a successful settings save, reload, or recovery. Draft edits
    /// are not consulted. Storage errors fall back to disabled intent.
    public func refreshPreferences() {
        reconcile()
    }

    /// Tickets authorize publication only; the caller must arrange bounded
    /// acquisition and cancel obsolete work. Latest request wins within session.
    public func beginAssetRequest() -> AssetRequest? {
        reconcile()
        guard let session = decision.assetSession else { return nil }
        let request = AssetRequest(session: session, id: UUID())
        pendingAsset = request
        return request
    }

    @discardableResult
    public func completeAssetRequest(_ request: AssetRequest, catalogue next: CompanionAssetCatalog?) -> Bool {
        reconcile()
        guard pendingAsset == request, policy.acceptsAssetResult(session: request.session) else {
            return false
        }
        pendingAsset = nil
        catalogue = next
        catalogueRevision = next == nil ? nil : UUID()
        reconcile(catalogueChanged: true)
        return true
    }

    /// Close the surface and revoke every outstanding asset publication.
    public func stop() {
        environment = .init()
        reconcile()
    }

    private func reconcile(catalogueChanged: Bool = false) {
        let preferences = store.load().preferences
        let decision = policy.reconcile(.init(preferences: preferences,
            releaseApproved: environment.releaseApproved, awake: environment.awake,
            ownsMenuSurface: environment.ownsMenuSurface,
            systemReduceMotion: environment.systemReduceMotion,
            catalogueRevision: catalogueRevision))
        let dropping = decision.assetSession == nil && catalogueRevision != nil
        if decision.assetSession == nil {
            pendingAsset = nil
            catalogue = nil
            catalogueRevision = nil
        }
        runtime.applyHostDecision(decision, catalog: catalogue,
            catalogueChanged: catalogueChanged || dropping)
    }
}
