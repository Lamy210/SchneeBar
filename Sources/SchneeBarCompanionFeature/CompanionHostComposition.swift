import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionEvents
import SchneeBarSystemProvider

/// The existing host grants exclusive ownership of an existing button's
/// image before creating this owner. One lifetime, no implicit reacquisition.
@MainActor
public final class CompanionHostComposition {
    public struct Demand: Equatable, Sendable {
        public let cpu: Bool
        public let localEventSession: UUID?
    }

    /// Frame callbacks may run inside runtime reconciliation. Report loss
    /// later on the main actor rather than synchronously reentering it.
    @MainActor
    private final class Binding {
        let surface = CompanionStatusImageSurface()
        let token: CompanionStatusImageSurface.Session
        var onLoss: (@MainActor () -> Void)?
        private var lossQueued = false

        init(button: NSButton) {
            token = surface.begin(on: button)
        }

        func check() -> Bool {
            let valid = surface.owns(token)
            if !valid { reportLoss() }
            return valid
        }

        func present(_ image: NSImage) {
            if !surface.present(image, in: token) { reportLoss() }
        }

        func clear() {
            if !surface.clear(in: token) { reportLoss() }
        }

        func end() {
            onLoss = nil
            surface.end(token)
        }

        private func reportLoss() {
            guard !lossQueued else { return }
            lossQueued = true
            Task { @MainActor [weak self] in self?.onLoss?() }
        }
    }

    private let binding: Binding
    private let store: CompanionHostPreferenceStore
    private let runtime: CompanionRuntimeCoordinator
    private let acquisition: CompanionOwnedAssetAcquisition
    private let cpu: CompanionSharedCPURefresh
    private let onDemandChanged: @MainActor (Demand) -> Void
    private var localTransport: CompanionLocalEventSessionOwner?
    public private(set) var automaticAssetRestoreEnabled = false
    private var handledRestoreSession: UUID?
    public private(set) var demand = Demand(cpu: false, localEventSession: nil)
    public private(set) var isStopped = false

    public private(set) lazy var settings = CompanionHostSettingsModel(
        store: store, onCommittedRefresh: { [weak self] in self?.refreshPreferences() }
    )

    public private(set) lazy var assetSettings = CompanionHostAssetSettingsModel(owner: self)

    /// No new status item, sampler, automatic event listener or CPU loop. The host must
    /// serialize its combined sampler demands and never reenter this owner
    /// synchronously from onDemandChanged.
    public convenience init(button: NSButton, store: CompanionHostPreferenceStore,
                sampler: HostCPUSampler, privateRoot: URL,
                onDemandChanged: @escaping @MainActor (Demand) -> Void = { _ in }) {
        self.init(button: button, store: store,
            load: { try CompanionOwnedPackStore.load(id: $0, from: privateRoot) },
            readSelection: { try CompanionOwnedPackStore.readSelection(in: privateRoot) },
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
            },
            makeCPU: { CompanionSharedCPURefresh(runtime: $0, sampler: sampler) },
            onDemandChanged: onDemandChanged)
    }

    init(button: NSButton, store: CompanionHostPreferenceStore,
         load: @escaping @Sendable (UUID) throws -> CompanionAssetCatalog,
         readSelection: (@Sendable () throws -> CompanionOwnedPackStore.ReadOnlySelection)? = nil,
         saveSelection: (@Sendable (UUID) throws -> CompanionOwnedPackStore.Selection)? = nil,
         clearSelection: (@Sendable () throws -> Void)? = nil,
         readInventory: (@Sendable () throws -> CompanionOwnedPackStore.Inventory)? = nil,
         installPack: (@Sendable (URL) throws -> UUID)? = nil,
         installImage: (@Sendable (URL) throws -> UUID)? = nil,
         manageLibrary: (@Sendable (CompanionOwnedAssetAcquisition.LibraryAction) throws -> Void)? = nil,
         makeCPU: (CompanionRuntimeCoordinator) -> CompanionSharedCPURefresh,
         onDemandChanged: @escaping @MainActor (Demand) -> Void = { _ in }) {
        let binding = Binding(button: button)
        let renderer = CompanionMenuBarRenderer(
            onFrame: { binding.present($0) }, onClear: { binding.clear() }
        )
        let runtime = CompanionRuntimeCoordinator(renderer: renderer)
        let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
        let acquisition = CompanionOwnedAssetAcquisition(bridge: bridge, load: load,
            readSelection: readSelection, saveSelection: saveSelection, clearSelection: clearSelection,
            readInventory: readInventory, installPack: installPack, installImage: installImage,
            manageLibrary: manageLibrary)
        self.binding = binding
        self.store = store
        self.runtime = runtime
        self.acquisition = acquisition
        self.cpu = makeCPU(runtime)
        self.onDemandChanged = onDemandChanged
        binding.onLoss = { [weak self] in self?.stop() }
        acquisition.onCompletion = { [weak self] in
            guard let self, !self.isStopped else { return }
            self.cpu.invalidate()
            self.publishDemand()
        }
        acquisition.onDrained = { [weak self] in
            guard let self else { return }
            self.publishDemand()
            // Queue idle callback is observation-only. Defer a pending
            // lifecycle restore until after the queue's finish returns.
            guard let session = self.pendingAutomaticRestoreSession else { return }
            Task { @MainActor [weak self] in
                guard let self, self.pendingAutomaticRestoreSession == session else { return }
                self.restoreAutomaticallyIfNeeded()
            }
        }
    }

    public var decision: CompanionHostPolicy.Decision { acquisition.decision }
    public var assetStatus: CompanionOwnedAssetAcquisition.Status { acquisition.status }
    public var assetInventory: CompanionOwnedPackStore.Inventory? { acquisition.inventory }
    public var assetInventoryStatus: CompanionOwnedAssetAcquisition.InventoryStatus { acquisition.inventoryStatus }
    public var assetPreviewStatus: CompanionOwnedAssetAcquisition.PreviewStatus { acquisition.previewStatus }
    public var assetThumbnail: CompanionPackThumbnail? { acquisition.thumbnail }
    public var assetImportStatus: CompanionOwnedAssetAcquisition.ImportStatus { acquisition.importStatus }
    public var assetLibraryStatus: CompanionOwnedAssetAcquisition.LibraryStatus { acquisition.libraryStatus }
    public var displayedPackID: UUID? { acquisition.displayedPackID }
    /// Retain this owner until false after stop before creating a successor.
    public var isAssetWorkerBusy: Bool { acquisition.isBusy }

    public func updateEnvironment(_ environment: CompanionHostRuntimeBridge.Environment) {
        guard !isStopped else { return }
        guard environment.ownsMenuSurface, binding.check() else { stop(); return }
        acquisition.updateEnvironment(environment)
        publishDemand()
        restoreAutomaticallyIfNeeded()
    }

    public func refreshPreferences() {
        guard !isStopped else { return }
        guard binding.check() else { stop(); return }
        acquisition.refreshPreferences()
        publishDemand()
        restoreAutomaticallyIfNeeded()
    }

    @discardableResult
    public func requestInstalledAsset(_ id: UUID) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.request(id)
        if accepted { handledRestoreSession = decision.assetSession }
        publishDemand()
        return accepted
    }

    /// Explicit read-only restore; never imports or writes a selection.
    @discardableResult
    public func restoreSavedAssetSelection() -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.restoreSavedSelection()
        if accepted { handledRestoreSession = decision.assetSession }
        publishDemand()
        return accepted
    }

    /// Explicit user action only, distinct from read-only display requests.
    @discardableResult
    public func saveInstalledAssetSelection(_ id: UUID) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.saveInstalledSelection(id)
        if accepted { handledRestoreSession = decision.assetSession }
        publishDemand()
        return accepted
    }

    /// Explicit deselection, not automatic repair of a broken record.
    @discardableResult
    public func clearSavedAssetSelection() -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.clearSavedSelection()
        if accepted { handledRestoreSession = decision.assetSession }
        publishDemand()
        return accepted
    }

    @discardableResult
    public func refreshAssetInventory() -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.refreshInventory()
        publishDemand()
        return accepted
    }

    @discardableResult
    public func requestAssetPreview(_ id: UUID) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.requestPreview(id)
        publishDemand()
        return accepted
    }

    /// The caller must pass the session captured before presenting the file
    /// chooser. A stale modal result must not gain new write authority.
    @discardableResult
    public func importAssetPack(from url: URL, session: UUID, singleImage: Bool = false) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        guard decision.assetSession == session else { return false }
        let accepted = acquisition.importPack(from: url, singleImage: singleImage)
        publishDemand()
        return accepted
    }

    public func canManageAssetLibrary(_ action: CompanionOwnedAssetAcquisition.LibraryAction) -> Bool {
        !isStopped && acquisition.canManage(action)
    }

    @discardableResult
    public func manageAssetLibrary(_ action: CompanionOwnedAssetAcquisition.LibraryAction) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.manage(action)
        publishDemand()
        return accepted
    }

    public func cancelAssetRequest() {
        guard !isStopped else { return }
        handledRestoreSession = decision.assetSession
        acquisition.cancel()
        publishDemand()
    }

    /// Explicit host opt-in, off by default. A newly admitted asset session
    /// gets at most one read-only restoration attempt; no periodic retries.
    public func enableAutomaticAssetRestore() {
        guard !isStopped else { return }
        automaticAssetRestoreEnabled = true
        restoreAutomaticallyIfNeeded()
    }

    /// Disable future automatic attempts. An already admitted read is not
    /// cancelled by this toggle; cancelAssetRequest() explicitly revokes it.
    public func disableAutomaticAssetRestore() {
        automaticAssetRestoreEnabled = false
    }

    private var pendingAutomaticRestoreSession: UUID? {
        guard automaticAssetRestoreEnabled, !isStopped,
              let session = decision.assetSession, session != handledRestoreSession
        else { return nil }
        return session
    }

    private func restoreAutomaticallyIfNeeded() {
        guard let session = pendingAutomaticRestoreSession else { return }
        guard binding.check() else { stop(); return }
        guard !acquisition.isBusy else { return }
        // Never replace an already admitted selection or repeat a failed
        // operation merely because the environment was refreshed.
        handledRestoreSession = session
        guard !decision.rendersCharacter, assetStatus == .idle else { return }
        _ = acquisition.restoreSavedSelection()
        publishDemand()
    }

    /// Invoke even in a no-CPU-demand host iteration to detect a lost slot.
    public func refreshCPU(isCurrent: @MainActor () -> Bool) async {
        guard !isStopped else { return }
        guard binding.check() else { stop(); return }
        await cpu.refresh { !self.isStopped && self.binding.check() && isCurrent() }
    }

    /// Separate, explicit transport attachment, off by default. The owner
    /// still requires committed event opt-in and an admitted catalogue.
    /// Choose this OR an external transport; do not register both.
    public func enableLocalNotificationTransport() {
        guard !isStopped, localTransport == nil else { return }
        guard binding.check() else { stop(); return }
        let transport = CompanionLocalEventSessionOwner { [weak self] session, kind, object in
            self?.receiveLocalEvent(session: session, kind: kind) {
                CompanionLocalNotificationSubscription.boundedPayload(object)
            }
        }
        localTransport = transport
        transport.update(session: demand.localEventSession)
    }

    public func disableLocalNotificationTransport() {
        let transport = localTransport
        localTransport = nil
        transport?.stop()
    }

    /// Transport entry point: an obsolete session or lost image slot must
    /// not even evaluate the untrusted payload. No privileged operation.
    @discardableResult
    public func receiveLocalEvent(
        session: UUID, kind: CompanionLocalEventIngress.Kind,
        payload: () -> CompanionLocalEventIngress.Payload
    ) -> CompanionLocalEventIngress.Outcome? {
        guard !isStopped else { return nil }
        guard binding.check() else { stop(); return nil }
        guard demand.localEventSession == session,
              runtime.localEventSession == session else { return nil }
        return runtime.receiveLocalEvent(session: session, kind: kind, payload: payload)
    }

    /// Host calls before replacing its scheduler configuration generation.
    public func invalidateCPU() {
        guard !isStopped else { return }
        cpu.invalidate()
    }

    /// Terminal and idempotent. Does not force native worker termination.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        disableAutomaticAssetRestore()
        disableLocalNotificationTransport()
        acquisition.stop()
        cpu.invalidate()
        binding.end()
        publishDemand()
    }

    private func publishDemand() {
        let active = !isStopped && binding.check()
        let next = Demand(cpu: active && runtime.wantsHostCPU,
            localEventSession: active ? runtime.localEventSession : nil)
        assetSettings.sync()
        if demand.cpu && !next.cpu { cpu.invalidate() }
        guard demand != next else { return }
        demand = next
        localTransport?.update(session: next.localEventSession)
        guard demand == next else { return }
        onDemandChanged(next)
    }
}
