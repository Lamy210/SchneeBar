import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore

/// Owns one read-only worker queue for the host's installed pack acquisition.
/// All environment and committed preference transitions must pass through
/// this adapter while it is attached. The root is app-owned and private.
@MainActor
public final class CompanionOwnedAssetAcquisition {
    public enum Status: Equatable, Sendable {
        case idle, loading(UUID), loaded(UUID), failed(UUID)
    }

    private let bridge: CompanionHostRuntimeBridge
    private let queue: CompanionImportQueue<UUID, CompanionAssetCatalog>
    private var pending: CompanionHostRuntimeBridge.AssetRequest?
    public private(set) var status: Status = .idle

    public convenience init(bridge: CompanionHostRuntimeBridge, privateRoot: URL) {
        self.init(bridge: bridge, load: { id in
            try CompanionOwnedPackStore.load(id: id, from: privateRoot)
        })
    }

    init(bridge: CompanionHostRuntimeBridge,
         load: @escaping @Sendable (UUID) throws -> CompanionAssetCatalog) {
        self.bridge = bridge
        queue = CompanionImportQueue(work: load)
    }

    public var decision: CompanionHostPolicy.Decision { bridge.decision }
    /// A cancelled non-cooperative worker retains its slot until it exits.
    public var isBusy: Bool { queue.isBusy }

    public func updateEnvironment(_ environment: CompanionHostRuntimeBridge.Environment) {
        bridge.updateEnvironment(environment)
        discardIfRevoked()
    }

    public func refreshPreferences() {
        bridge.refreshPreferences()
        discardIfRevoked()
    }

    /// Explicit installed UUID only; no writes, selection changes or imports.
    @discardableResult
    public func request(_ id: UUID) -> Bool {
        guard let ticket = bridge.beginAssetRequest() else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        status = .loading(id)
        queue.submit(id) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            self.pending = nil
            switch result {
            case .success(let catalogue):
                self.status = self.bridge.completeAssetRequest(ticket, catalogue: catalogue)
                    ? .loaded(id) : .idle
            case .failure:
                self.status = self.bridge.completeAssetRequest(ticket, catalogue: nil)
                    ? .failed(id) : .idle
            }
        }
        return true
    }

    /// Cancels acquisition but preserves an already admitted catalogue.
    public func cancel() {
        if let pending {
            bridge.cancelAssetRequest(pending)
            self.pending = nil
        }
        queue.cancel()
        status = .idle
    }

    /// Stop before releasing the host surface; revoke catalogue and requests.
    public func stop() {
        bridge.stop()
        cancel()
    }

    private func discardIfRevoked() {
        if bridge.decision.assetSession == nil { cancel() }
    }
}
