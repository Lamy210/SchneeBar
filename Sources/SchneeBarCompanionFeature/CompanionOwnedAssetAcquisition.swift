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
        case restoring, noSavedSelection, savedAssetUnavailable(UUID), restoreFailed
    }

    private let bridge: CompanionHostRuntimeBridge
    private enum Request: Sendable { case installed(UUID), saved }
    private typealias Selection = CompanionOwnedPackStore.ReadOnlySelection
    private let queue: CompanionImportQueue<Request, Selection>
    private let canReadSelection: Bool
    private var pending: CompanionHostRuntimeBridge.AssetRequest?
    public private(set) var status: Status = .idle
    /// The owner observes the final adopted result, not intermediate queue
    /// state. Must not synchronously reenter the acquisition adapter.
    var onCompletion: (@MainActor () -> Void)?

    public convenience init(bridge: CompanionHostRuntimeBridge, privateRoot: URL) {
        self.init(bridge: bridge, load: { id in
            try CompanionOwnedPackStore.load(id: id, from: privateRoot)
        }, readSelection: { try CompanionOwnedPackStore.readSelection(in: privateRoot) })
    }

    init(bridge: CompanionHostRuntimeBridge,
         load: @escaping @Sendable (UUID) throws -> CompanionAssetCatalog,
         readSelection: (@Sendable () throws -> CompanionOwnedPackStore.ReadOnlySelection)? = nil) {
        self.bridge = bridge
        canReadSelection = readSelection != nil
        queue = CompanionImportQueue { request in
            switch request {
            case .installed(let id): return .installed(id: id, catalogue: try load(id))
            case .saved:
                guard let readSelection else { throw CancellationError() }
                return try readSelection()
            }
        }
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
        submit(.installed(id), status: .loading(id), failure: .failed(id))
    }

    /// Read-only explicit restore. Missing/invalid saved assets clear the
    /// admitted catalogue but do not modify the selection file.
    @discardableResult
    public func restoreSavedSelection() -> Bool {
        guard canReadSelection else { return false }
        return submit(.saved, status: .restoring, failure: .restoreFailed)
    }

    private func submit(_ request: Request, status: Status, failure: Status) -> Bool {
        guard let ticket = bridge.beginAssetRequest() else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        self.status = status
        queue.submit(request) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            self.pending = nil
            let catalogue: CompanionAssetCatalog?
            let adoptedStatus: Status
            switch result {
            case .success(.installed(let id, let value)):
                catalogue = value
                adoptedStatus = .loaded(id)
            case .success(.builtIn):
                catalogue = nil
                adoptedStatus = .noSavedSelection
            case .success(.unavailable(let id)):
                catalogue = nil
                adoptedStatus = .savedAssetUnavailable(id)
            case .failure:
                catalogue = nil
                adoptedStatus = failure
            }
            self.status = self.bridge.completeAssetRequest(ticket, catalogue: catalogue)
                ? adoptedStatus : .idle
            self.onCompletion?()
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
