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
    public private(set) var demand = Demand(cpu: false, localEventSession: nil)
    public private(set) var isStopped = false

    public private(set) lazy var settings = CompanionHostSettingsModel(
        store: store, onCommittedRefresh: { [weak self] in self?.refreshPreferences() }
    )

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
            makeCPU: { CompanionSharedCPURefresh(runtime: $0, sampler: sampler) },
            onDemandChanged: onDemandChanged)
    }

    init(button: NSButton, store: CompanionHostPreferenceStore,
         load: @escaping @Sendable (UUID) throws -> CompanionAssetCatalog,
         readSelection: (@Sendable () throws -> CompanionOwnedPackStore.ReadOnlySelection)? = nil,
         saveSelection: (@Sendable (UUID) throws -> CompanionOwnedPackStore.Selection)? = nil,
         clearSelection: (@Sendable () throws -> Void)? = nil,
         makeCPU: (CompanionRuntimeCoordinator) -> CompanionSharedCPURefresh,
         onDemandChanged: @escaping @MainActor (Demand) -> Void = { _ in }) {
        let binding = Binding(button: button)
        let renderer = CompanionMenuBarRenderer(
            onFrame: { binding.present($0) }, onClear: { binding.clear() }
        )
        let runtime = CompanionRuntimeCoordinator(renderer: renderer)
        let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
        let acquisition = CompanionOwnedAssetAcquisition(bridge: bridge, load: load,
            readSelection: readSelection, saveSelection: saveSelection, clearSelection: clearSelection)
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
    }

    public var decision: CompanionHostPolicy.Decision { acquisition.decision }
    public var assetStatus: CompanionOwnedAssetAcquisition.Status { acquisition.status }
    /// Retain this owner until false after stop before creating a successor.
    public var isAssetWorkerBusy: Bool { acquisition.isBusy }

    public func updateEnvironment(_ environment: CompanionHostRuntimeBridge.Environment) {
        guard !isStopped else { return }
        guard environment.ownsMenuSurface, binding.check() else { stop(); return }
        acquisition.updateEnvironment(environment)
        publishDemand()
    }

    public func refreshPreferences() {
        guard !isStopped else { return }
        guard binding.check() else { stop(); return }
        acquisition.refreshPreferences()
        publishDemand()
    }

    @discardableResult
    public func requestInstalledAsset(_ id: UUID) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.request(id)
        publishDemand()
        return accepted
    }

    /// Explicit read-only restore; never imports or writes a selection.
    @discardableResult
    public func restoreSavedAssetSelection() -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.restoreSavedSelection()
        publishDemand()
        return accepted
    }

    /// Explicit user action only, distinct from read-only display requests.
    @discardableResult
    public func saveInstalledAssetSelection(_ id: UUID) -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.saveInstalledSelection(id)
        publishDemand()
        return accepted
    }

    /// Explicit deselection, not automatic repair of a broken record.
    @discardableResult
    public func clearSavedAssetSelection() -> Bool {
        guard !isStopped else { return false }
        guard binding.check() else { stop(); return false }
        let accepted = acquisition.clearSavedSelection()
        publishDemand()
        return accepted
    }

    public func cancelAssetRequest() {
        guard !isStopped else { return }
        acquisition.cancel()
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
        if demand.cpu && !next.cpu { cpu.invalidate() }
        guard demand != next else { return }
        demand = next
        localTransport?.update(session: next.localEventSession)
        guard demand == next else { return }
        onDemandChanged(next)
    }
}
