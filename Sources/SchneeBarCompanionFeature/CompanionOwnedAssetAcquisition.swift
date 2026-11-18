import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore

/// Owns one worker queue for host acquisition and explicit selection commits.
/// All environment and committed preference transitions must pass through
/// this adapter while it is attached. The root is app-owned and private.
@MainActor
public final class CompanionOwnedAssetAcquisition {
    public enum Status: Equatable, Sendable {
        case idle, loading(UUID), loaded(UUID), failed(UUID)
        case restoring, noSavedSelection, savedAssetUnavailable(UUID), restoreFailed
        case savingSelection(UUID), clearingSelection, selectionSaved(UUID), selectionCleared, selectionCommitFailed
    }

    private let bridge: CompanionHostRuntimeBridge
    private enum Request: Sendable {
        case installed(UUID), saved, save(UUID), clearSaved, inventory, preview(UUID)
        var requiresExclusiveSlot: Bool {
            switch self {
            case .save, .clearSaved, .inventory, .preview: true
            case .installed, .saved: false
            }
        }
    }
    private enum CommitError: Error { case unexpectedSelection }
    private typealias Selection = CompanionOwnedPackStore.ReadOnlySelection
    private enum Output: Sendable {
        case selection(Selection)
        case inventory(CompanionOwnedPackStore.Inventory)
        case preview(CompanionPackThumbnail)
    }
    public enum InventoryStatus: Equatable, Sendable { case idle, loading, loaded, failed }
    public private(set) var inventory: CompanionOwnedPackStore.Inventory?
    public private(set) var inventoryStatus: InventoryStatus = .idle
    public enum PreviewStatus: Equatable, Sendable { case idle, loading(UUID), loaded(UUID), failed(UUID) }
    public private(set) var previewStatus: PreviewStatus = .idle
    public private(set) var thumbnail: CompanionPackThumbnail?
    private let queue: CompanionImportQueue<Request, Output>
    private let canReadInventory: Bool
    private let canReadSelection: Bool
    private let canSaveSelection: Bool
    private let canClearSelection: Bool
    private var exclusiveInFlight = false
    private var pending: CompanionHostRuntimeBridge.AssetRequest?
    public private(set) var status: Status = .idle
    /// The owner observes the final adopted result, not intermediate queue
    /// state. Must not synchronously reenter the acquisition adapter.
    var onCompletion: (@MainActor () -> Void)?
    var onDrained: (@MainActor () -> Void)?

    public convenience init(bridge: CompanionHostRuntimeBridge, privateRoot: URL) {
        self.init(bridge: bridge, load: { id in
            try CompanionOwnedPackStore.load(id: id, from: privateRoot)
        }, readSelection: { try CompanionOwnedPackStore.readSelection(in: privateRoot) },
            saveSelection: { try CompanionOwnedPackStore.select(id: $0, in: privateRoot) },
            clearSelection: { try CompanionOwnedPackStore.selectBuiltIn(in: privateRoot) },
            readInventory: { try CompanionOwnedPackStore.inventory(in: privateRoot) })
    }

    init(bridge: CompanionHostRuntimeBridge,
         load: @escaping @Sendable (UUID) throws -> CompanionAssetCatalog,
         readSelection: (@Sendable () throws -> CompanionOwnedPackStore.ReadOnlySelection)? = nil,
         saveSelection: (@Sendable (UUID) throws -> CompanionOwnedPackStore.Selection)? = nil,
         clearSelection: (@Sendable () throws -> Void)? = nil,
         readInventory: (@Sendable () throws -> CompanionOwnedPackStore.Inventory)? = nil) {
        self.bridge = bridge
        canReadSelection = readSelection != nil
        canSaveSelection = saveSelection != nil
        canClearSelection = clearSelection != nil
        canReadInventory = readInventory != nil
        queue = CompanionImportQueue { request in
            switch request {
            case .installed(let id): return .selection(.installed(id: id, catalogue: try load(id)))
            case .saved:
                guard let readSelection else { throw CancellationError() }
                return .selection(try readSelection())
            case .save(let id):
                guard let saveSelection,
                      case let .installed(savedID, catalogue) = try saveSelection(id), savedID == id
                else { throw CommitError.unexpectedSelection }
                return .selection(.installed(id: savedID, catalogue: catalogue))
            case .clearSaved:
                guard let clearSelection else { throw CommitError.unexpectedSelection }
                try clearSelection()
                return .selection(.builtIn)
            case .inventory:
                guard let readInventory else { throw CancellationError() }
                return .inventory(try readInventory())
            case .preview(let id):
                return .preview(try CompanionPackThumbnail(catalogue: load(id)))
            }
        }
        queue.onIdle = { [weak self] in self?.onDrained?() }
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

    /// Explicit durable selection. Never supersede a running write and never
    /// start a write while an earlier read or cancelled worker is draining.
    @discardableResult
    public func saveInstalledSelection(_ id: UUID) -> Bool {
        guard canSaveSelection else { return false }
        return submit(.save(id), status: .savingSelection(id), failure: .selectionCommitFailed)
    }

    @discardableResult
    public func clearSavedSelection() -> Bool {
        guard canClearSelection else { return false }
        return submit(.clearSaved, status: .clearingSelection, failure: .selectionCommitFailed)
    }

    /// Explicit metadata-only refresh. No catalogue replacement, CPU reset
    /// or selection write. Share the existing worker slot.
    @discardableResult
    public func refreshInventory() -> Bool {
        guard canReadInventory, !queue.isBusy else { return false }
        guard let ticket = bridge.beginAssetRequest(),
              let session = bridge.decision.assetSession else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        exclusiveInFlight = true
        clearPreview()
        inventory = nil
        inventoryStatus = .loading
        queue.submit(.inventory) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            self.pending = nil
            self.exclusiveInFlight = false
            self.bridge.refreshPreferences()
            self.bridge.cancelAssetRequest(ticket)
            guard self.bridge.decision.assetSession == session else {
                self.cancel()
                self.onCompletion?()
                return
            }
            if case let .success(.inventory(value)) = result {
                self.inventory = value
                self.inventoryStatus = .loaded
            } else {
                self.inventoryStatus = .failed
            }
        }
        return true
    }

    /// Validate the chosen pack in the existing worker, then retain one
    /// small static bitmap. Never adopt the catalogue or persist selection.
    @discardableResult
    public func requestPreview(_ id: UUID) -> Bool {
        guard !queue.isBusy else { return false }
        guard let ticket = bridge.beginAssetRequest(),
              let session = bridge.decision.assetSession else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        exclusiveInFlight = true
        thumbnail = nil
        previewStatus = .loading(id)
        queue.submit(.preview(id)) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            self.pending = nil
            self.exclusiveInFlight = false
            self.bridge.refreshPreferences()
            self.bridge.cancelAssetRequest(ticket)
            guard self.bridge.decision.assetSession == session else {
                self.cancel()
                self.onCompletion?()
                return
            }
            if case let .success(.preview(value)) = result {
                self.thumbnail = value
                self.previewStatus = .loaded(id)
            } else {
                self.previewStatus = .failed(id)
            }
        }
        return true
    }

    private func clearPreview() {
        thumbnail = nil
        previewStatus = .idle
    }

    private func submit(_ request: Request, status: Status, failure: Status) -> Bool {
        guard !queue.isBusy || (!exclusiveInFlight && !request.requiresExclusiveSlot) else { return false }
        guard let ticket = bridge.beginAssetRequest() else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        exclusiveInFlight = request.requiresExclusiveSlot
        clearPreview()
        self.status = status
        queue.submit(request) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            self.pending = nil
            self.exclusiveInFlight = false
            let catalogue: CompanionAssetCatalog?
            let adoptedStatus: Status
            switch result {
            case .success(.selection(.installed(let id, let value))):
                catalogue = value
                adoptedStatus = request.requiresExclusiveSlot ? .selectionSaved(id) : .loaded(id)
            case .success(.selection(.builtIn)):
                catalogue = nil
                adoptedStatus = request.requiresExclusiveSlot ? .selectionCleared : .noSavedSelection
            case .success(.selection(.unavailable(let id))):
                catalogue = nil
                adoptedStatus = .savedAssetUnavailable(id)
            case .failure, .success(.inventory), .success(.preview):
                catalogue = nil
                adoptedStatus = failure
            }
            self.status = self.bridge.completeAssetRequest(ticket, catalogue: catalogue)
                ? adoptedStatus : .idle
            self.onCompletion?()
        }
        return true
    }

    /// Cancels publication but preserves an already admitted catalogue.
    /// A durable write may already have committed; read the saved choice
    /// after the slot drains. Cancellation is not a disk rollback.
    public func cancel() {
        if let pending {
            bridge.cancelAssetRequest(pending)
            self.pending = nil
        }
        queue.cancel()
        clearPreview()
        inventory = nil
        inventoryStatus = .idle
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
