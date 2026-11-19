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

    public enum LibraryAction: Equatable, Sendable {
        case trash(UUID), restore(UUID), purge(UUID), discardStage(UUID), discardPendingSelection

        public var requiresTypedConfirmation: Bool {
            switch self {
            case .purge, .discardStage, .discardPendingSelection: true
            case .trash, .restore: false
            }
        }
    }
    public enum LibraryStatus: Equatable, Sendable {
        case idle, working(LibraryAction), completed(LibraryAction), failed(LibraryAction)
    }
    public private(set) var libraryStatus: LibraryStatus = .idle
    // Independent of transient operation status; cancel preserves an admitted catalogue.
    private var admittedID: UUID?
    public var displayedPackID: UUID? { decision.rendersCharacter ? admittedID : nil }
    private let canManageLibrary: Bool
    private let bridge: CompanionHostRuntimeBridge
    private enum Request: Sendable {
        case installed(UUID), saved, save(UUID), clearSaved, inventory, preview(UUID), install(URL, singleImage: Bool), manage(LibraryAction)
        var requiresExclusiveSlot: Bool {
            switch self {
            case .save, .clearSaved, .inventory, .preview, .install, .manage: true
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
        case installedPack(UUID)
        case managed
    }
    public enum InventoryStatus: Equatable, Sendable { case idle, loading, loaded, failed }
    public private(set) var inventory: CompanionOwnedPackStore.Inventory?
    public private(set) var inventoryStatus: InventoryStatus = .idle
    public enum PreviewStatus: Equatable, Sendable { case idle, loading(UUID), loaded(UUID), failed(UUID) }
    public private(set) var previewStatus: PreviewStatus = .idle
    public private(set) var thumbnail: CompanionPackThumbnail?
    private let queue: CompanionImportQueue<Request, Output>
    public enum ImportStatus: Equatable, Sendable { case idle, importing, installed(UUID), failed }
    public private(set) var importStatus: ImportStatus = .idle
    private let canInstallPack: Bool
    private let canInstallImage: Bool
    private let canReadInventory: Bool
    private let canReadSelection: Bool
    private let canSaveSelection: Bool
    private let canClearSelection: Bool
    private var exclusiveInFlight = false
    private var pending: CompanionHostRuntimeBridge.AssetRequest?
    public private(set) var status: Status = .idle
    /// The owner observes the final adopted result, not intermediate queue
    /// state. Must not synchronously reenter the acquisition adapter.
    /// Optional host-owned publication gate. Must not synchronously reenter
    /// this adapter. Checked even for metadata and already committed writes.
    var canPublish: (@MainActor () -> Bool)?
    var onCompletion: (@MainActor () -> Void)?
    var onDrained: (@MainActor () -> Void)?

    public convenience init(bridge: CompanionHostRuntimeBridge, privateRoot: URL) {
        self.init(bridge: bridge, load: { id in
            try CompanionOwnedPackStore.load(id: id, from: privateRoot)
        }, readSelection: { try CompanionOwnedPackStore.readSelection(in: privateRoot) },
            saveSelection: { try CompanionOwnedPackStore.select(id: $0, in: privateRoot) },
            clearSelection: { try CompanionOwnedPackStore.selectBuiltIn(in: privateRoot) },
            readInventory: { try CompanionOwnedPackStore.inventory(in: privateRoot) },
            installPack: { try CompanionOwnedPackStore.install(from: $0, into: privateRoot).id },
            installImage: { try CompanionOwnedPackStore.installImage(from: $0, into: privateRoot).id },
            manageLibrary: { action in
                switch action {
                case .trash(let id): try CompanionOwnedPackStore.trashUnselected(id: id, in: privateRoot)
                case .restore(let id): try CompanionOwnedPackStore.restore(id: id, in: privateRoot)
                case .purge(let id): try CompanionOwnedPackStore.purgeUnselectedTrash(id: id, in: privateRoot)
                case .discardStage(let id): try CompanionOwnedPackStore.discardAbandonedStage(id: id, in: privateRoot)
                case .discardPendingSelection: try CompanionOwnedPackStore.discardPendingSelection(in: privateRoot)
                }
            })
    }

    init(bridge: CompanionHostRuntimeBridge,
         load: @escaping @Sendable (UUID) throws -> CompanionAssetCatalog,
         readSelection: (@Sendable () throws -> CompanionOwnedPackStore.ReadOnlySelection)? = nil,
         saveSelection: (@Sendable (UUID) throws -> CompanionOwnedPackStore.Selection)? = nil,
         clearSelection: (@Sendable () throws -> Void)? = nil,
         readInventory: (@Sendable () throws -> CompanionOwnedPackStore.Inventory)? = nil,
         installPack: (@Sendable (URL) throws -> UUID)? = nil,
         installImage: (@Sendable (URL) throws -> UUID)? = nil,
         manageLibrary: (@Sendable (LibraryAction) throws -> Void)? = nil) {
        self.bridge = bridge
        canReadSelection = readSelection != nil
        canSaveSelection = saveSelection != nil
        canClearSelection = clearSelection != nil
        canReadInventory = readInventory != nil
        canInstallPack = installPack != nil
        canInstallImage = installImage != nil
        canManageLibrary = manageLibrary != nil
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
            case .install(let url, let singleImage):
                guard let install = singleImage ? installImage : installPack else { throw CancellationError() }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return .installedPack(try install(url))
            case .manage(let action):
                guard let manageLibrary else { throw CancellationError() }
                try manageLibrary(action)
                return .managed
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
            guard self.canPublish?() != false else {
                self.stop()
                self.onCompletion?()
                return
            }
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
            guard self.canPublish?() != false else {
                self.stop()
                self.onCompletion?()
                return
            }
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

    /// Explicit copy into the private library. Never select or adopt the
    /// returned catalogue. The store enforces its own slot and recovery limits.
    @discardableResult
    public func importPack(from url: URL, singleImage: Bool = false) -> Bool {
        guard (singleImage ? canInstallImage : canInstallPack), !queue.isBusy, url.isFileURL else { return false }
        guard let ticket = bridge.beginAssetRequest(),
              let session = bridge.decision.assetSession else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        exclusiveInFlight = true
        clearPreview()
        inventory = nil
        inventoryStatus = .idle
        importStatus = .importing
        queue.submit(.install(url, singleImage: singleImage)) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            guard self.canPublish?() != false else {
                self.stop()
                self.onCompletion?()
                return
            }
            self.pending = nil
            self.exclusiveInFlight = false
            self.bridge.refreshPreferences()
            self.bridge.cancelAssetRequest(ticket)
            guard self.bridge.decision.assetSession == session else {
                self.cancel()
                self.onCompletion?()
                return
            }
            if case let .success(.installedPack(id)) = result {
                self.importStatus = .installed(id)
            } else {
                self.importStatus = .failed
            }
        }
        return true
    }

    /// Explicit library changes only. A current inventory is required;
    /// the store checks the persisted selection again under its root lock.
    public func canManage(_ action: LibraryAction) -> Bool {
        guard canManageLibrary, !queue.isBusy, decision.assetSession != nil,
              let inventory else { return false }
        switch action {
        case .trash(let id):
            guard !decision.rendersCharacter || (admittedID != nil && admittedID != id) else { return false }
            return inventory.entries.contains { $0.id == id }
        case .restore(let id):
            return inventory.trashedIDs.contains(id)
        case .purge(let id):
            guard !decision.rendersCharacter || (admittedID != nil && admittedID != id) else { return false }
            return inventory.trashedIDs.contains(id)
        case .discardStage(let id):
            return inventory.abandonedStageIDs.contains(id)
        case .discardPendingSelection:
            return inventory.pendingSelectionRecovery
        }
    }

    @discardableResult
    public func manage(_ action: LibraryAction) -> Bool {
        guard canManage(action), let ticket = bridge.beginAssetRequest(),
              let session = bridge.decision.assetSession else {
            discardIfRevoked()
            return false
        }
        pending = ticket
        exclusiveInFlight = true
        clearPreview()
        inventory = nil
        inventoryStatus = .idle
        libraryStatus = .working(action)
        queue.submit(.manage(action)) { [weak self] result in
            guard let self, self.pending == ticket else { return }
            guard self.canPublish?() != false else {
                self.stop()
                self.onCompletion?()
                return
            }
            self.pending = nil
            self.exclusiveInFlight = false
            self.bridge.refreshPreferences()
            self.bridge.cancelAssetRequest(ticket)
            guard self.bridge.decision.assetSession == session else {
                self.cancel()
                self.onCompletion?()
                return
            }
            if case .success(.managed) = result {
                self.libraryStatus = .completed(action)
            } else {
                self.libraryStatus = .failed(action)
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
            guard self.canPublish?() != false else {
                self.stop()
                self.onCompletion?()
                return
            }
            self.pending = nil
            self.exclusiveInFlight = false
            let catalogue: CompanionAssetCatalog?
            let adoptedStatus: Status
            var nextID: UUID?
            switch result {
            case .success(.selection(.installed(let id, let value))):
                catalogue = value
                nextID = id
                adoptedStatus = request.requiresExclusiveSlot ? .selectionSaved(id) : .loaded(id)
            case .success(.selection(.builtIn)):
                catalogue = nil
                adoptedStatus = request.requiresExclusiveSlot ? .selectionCleared : .noSavedSelection
            case .success(.selection(.unavailable(let id))):
                catalogue = nil
                adoptedStatus = .savedAssetUnavailable(id)
            case .failure, .success(.inventory), .success(.preview), .success(.installedPack), .success(.managed):
                catalogue = nil
                adoptedStatus = failure
            }
            let adopted = self.bridge.completeAssetRequest(ticket, catalogue: catalogue)
            self.status = adopted ? adoptedStatus : .idle
            self.admittedID = adopted ? nextID : nil
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
        importStatus = .idle
        libraryStatus = .idle
        if !decision.rendersCharacter { admittedID = nil }
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
