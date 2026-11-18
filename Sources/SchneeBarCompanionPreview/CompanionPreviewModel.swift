import AppKit
import Combine
import CoreGraphics
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionFeature
import SchneeBarCompanionEvents
import SchneeBarSystemProvider
import UniformTypeIdentifiers

/// Developer preview only. Separate character selection storage; no network, login items or GitHub.
@MainActor
final class CompanionPreviewModel: NSObject, ObservableObject {
    enum ImageSource: Equatable { case builtIn, selectedFile, installedPack(UUID) }
    var imageSourceTitle: String {
        switch imageSource {
        case .builtIn: "Built-in"
        case .selectedFile: "Selected file (session only)"
        case .installedPack: "Saved pack"
        }
    }
    @Published private(set) var libraryBusy = false
    @Published private(set) var libraryInventory: CompanionOwnedPackStore.Inventory?
    @Published private(set) var libraryMessage = ""
    @Published private(set) var libraryThumbnails: [UUID: CGImage] = [:]
    private let libraryRoot: URL?
    private var libraryNeedsRestore = false
    var libraryAvailable: Bool { libraryRoot != nil }
    var canUseLibrary: Bool {
        libraryAvailable && imageSelectionSession != nil && !libraryBusy && !imageImportPending
    }
    @Published private(set) var imageSource: ImageSource = .builtIn
    @Published private(set) var imageMessage = ""
    @Published private(set) var imageImportPending = false
    @Published private(set) var imageSelectionSession: UUID?

    @Published private(set) var started = false
    @Published private(set) var message = ""
    @Published private(set) var cpuText = ""
    @Published private(set) var state: CompanionState = .run
    @Published private(set) var effectiveRate: Double = 1
    @Published var showCharacter = true { didSet { reconcile() } }
    @Published var showCPU = false { didSet { reconcile() } }
    @Published var automatic = true { didSet { reconcile() } }
    @Published var manualRate: CompanionPlaybackRate = .normal { didSet { reconcile() } }
    @Published var freeze = false { didSet { reconcile() } }
    @Published var listenToLocalEvents = false { didSet { reconcile() } }
    private var localSubscription: PreviewLocalNotificationSubscription?
    private var subscribedSession: UUID?

    private let imageQueue: CompanionImportQueue<URL, CompanionAssetCatalog>
    private let sampler: HostCPUSampler
    private let conflictingApplication: @MainActor () -> String?
    private let makeStatusItem: @MainActor () -> NSStatusItem?
    private let systemReduceMotion: @MainActor () -> Bool
    private let allowHeadlessPresentation: Bool
    private let waitForNextPoll: @Sendable (Duration) async throws -> Void
    private var item: NSStatusItem?
    private var fallback: NSImage? {
        NSImage(systemSymbolName: "snowflake", accessibilityDescription: "SchneeBar Preview")
    }
    private lazy var runtime: CompanionRuntimeCoordinator = {
        let coordinator = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(
        onFrame: { [weak self] image in self?.item?.button?.image = image },
        onClear: { [weak self] in
            guard let self else { return }
            self.item?.button?.image = self.fallback
        }
        ))
        coordinator.onStateChange = { [weak self] state, rate in
            self?.state = state
            self?.effectiveRate = rate.factor
        }
        return coordinator
    }()
    private var transition: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var revision = UUID()
    private var sleeping = false

    init(
        sampler: HostCPUSampler = HostCPUSampler(),
        conflictingApplication: @escaping @MainActor () -> String? = {
            CompanionPreviewModel.runningConflict()
        },
        makeStatusItem: @escaping @MainActor () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        },
        systemReduceMotion: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        allowHeadlessPresentation: Bool = false,
        waitForNextPoll: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        imageQueue: CompanionImportQueue<URL, CompanionAssetCatalog>? = nil,
        libraryRoot: URL? = nil
    ) {
        self.imageQueue = imageQueue ?? CompanionSingleFileImporter.makeQueue()
        self.libraryRoot = libraryRoot ?? (allowHeadlessPresentation ? nil : PreviewPackLibrary.defaultRoot())
        self.sampler = sampler
        self.conflictingApplication = conflictingApplication
        self.makeStatusItem = makeStatusItem
        self.systemReduceMotion = systemReduceMotion
        self.allowHeadlessPresentation = allowHeadlessPresentation
        self.waitForNextPoll = waitForNextPoll
        super.init()
    }

    /// Cooperative check for known app bundle identities, not an atomic lock.
    /// Unbundled development executables and simultaneous launches are not
    /// covered. Keep this preview isolated from both shipping applications.
    private static func runningConflict() -> String? {
        let candidates = [
            ("dev.lamy.schneebar", "SchneeBar"),
            ("io.github.Lamy210.SchneeRunner", "SchneeRunner"),
            ("dev.lamy.schneebar.companion-preview", "another Companion Preview"),
        ]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for (identifier, name) in candidates {
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains(where: { $0.processIdentifier != ownPID && !$0.isTerminated }) {
                return name
            }
        }
        return nil
    }

    func start() {
        guard !started else { return }
        guard !libraryBusy else { message = "Library operation is still finishing."; return }
        if let conflict = conflictingApplication() {
            message = "Quit \(conflict) before starting the isolated preview."
            return
        }
        do {
            runtime.setCatalog(try CompanionPreviewAssets.catalogue())
        } catch {
            message = "Unable to create preview assets."
            return
        }
        let statusItem = makeStatusItem()
        // In the real preview a failed status surface must not leave a
        // headless polling/animation loop. Only tests opt into that mode.
        guard allowHeadlessPresentation || statusItem?.button != nil else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            runtime.setCatalog(nil)
            message = "Unable to create preview status item."
            return
        }
        item = statusItem
        statusItem?.button?.image = fallback
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(activateWindow)
        statusItem?.button?.setAccessibilityLabel("SchneeBar Companion Preview")
        imageSource = .builtIn
        imageMessage = ""
        started = true
        message = ""
        libraryNeedsRestore = libraryAvailable
        reconcile()
    }

    func stop() {
        guard started else { return }
        started = false
        libraryNeedsRestore = false
        libraryInventory = nil
        libraryMessage = ""
        reconcile()
        runtime.setCatalog(nil)
        imageSource = .builtIn
        imageMessage = ""
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Explicit selection only; no automatic discovery, bookmarks or copies.
    /// The modal panel can run nested events, so capture and recheck session
    /// identity before handing any result to the asynchronous importer.
    func chooseImage() {
        guard !libraryBusy, let session = imageSelectionSession else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose preview image"
        panel.message = "Choose a PNG, APNG, GIF or WebP that you have permission to use."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.png, .gif, .webP] +
            [UTType(filenameExtension: "apng")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(url, session: session)
    }

    /// Internal selection seam for deterministic tests. All native panel
    /// results and worker completions are fenced against lifecycle changes.
    func importImage(_ url: URL, session: UUID) {
        guard !libraryBusy, imageSelectionSession == session else { return }
        libraryNeedsRestore = false
        imageImportPending = true
        imageMessage = "Loading selected image…"
        imageQueue.submit(url) { [weak self] result in
            guard let self, self.imageSelectionSession == session else { return }
            self.imageImportPending = false
            switch result {
            case let .success(catalogue):
                self.runtime.setCatalog(catalogue)
                self.imageSource = .selectedFile
                self.imageMessage = "Selected image loaded for this session."
                self.updatePresentation()
            case .failure:
                // Keep the last successful catalogue; never disclose a path
                // or raw system error in the status item or preview label.
                self.imageMessage = "Unable to load image. Current image retained."
            }
        }
    }

    func restoreBuiltInImage() {
        guard !libraryBusy, imageSelectionSession != nil else { return }
        libraryNeedsRestore = false
        do {
            let catalogue = try CompanionPreviewAssets.catalogue()
            imageQueue.cancel()
            imageImportPending = false
            runtime.setCatalog(catalogue)
            imageSource = .builtIn
            imageMessage = "Default image restored."
            updatePresentation()
        } catch {
            imageMessage = "Unable to restore default image. Current image retained."
        }
    }

    private func reconcileImageSession() {
        if started && showCharacter && !sleeping {
            if imageSelectionSession == nil { imageSelectionSession = UUID() }
            restoreLibraryIfNeeded()
        } else if imageSelectionSession != nil {
            imageSelectionSession = nil
            libraryThumbnails.removeAll()
            if started && libraryBusy { libraryNeedsRestore = true }
            imageQueue.cancel()
            imageImportPending = false
            imageMessage = ""
        }
    }

    func choosePack() {
        guard canUseLibrary, let session = imageSelectionSession,
              libraryInventory?.canInstall == true else { return }
        let panel = NSOpenPanel()
        panel.title = "Import character pack"
        panel.message = "Choose a .schneerunner directory you have permission to use. A copy will be saved."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url,
              imageSelectionSession == session else { return }
        importPack(url)
    }

    func importPack(_ url: URL) {
        guard libraryInventory?.canInstall == true else { return }
        runLibrary(.install(url))
    }
    func refreshLibrary() { runLibrary(.refresh) }

    func loadThumbnail(_ id: UUID) {
        guard libraryThumbnails[id] == nil,
              libraryInventory?.entries.contains(where: { $0.id == id && $0.name != nil }) == true else { return }
        runLibrary(.thumbnail(id))
    }
    func restoreSavedChoice() { runLibrary(.restoreSelection) }
    func selectPack(_ id: UUID) { runLibrary(.select(id)) }
    func selectLibraryDefault() { runLibrary(.builtIn) }

    enum RecoveryAction: Equatable {
        case trash(UUID), restore(UUID), purge(UUID), discardStage(UUID), discardPendingSelection

        var title: String {
            switch self {
            case .trash: "Move to trash"
            case .restore: "Restore pack"
            case .purge: "Permanently delete pack"
            case .discardStage: "Discard abandoned import"
            case .discardPendingSelection: "Discard uncommitted selection"
            }
        }

        var detail: String {
            switch self {
            case .trash(let id): "Move the owned copy \(id.uuidString) to trash. The original source is unchanged."
            case .restore(let id): "Restore the owned copy \(id.uuidString) without selecting it."
            case .purge(let id): "Permanently remove the owned trash entry \(id.uuidString). This cannot be undone."
            case .discardStage(let id): "Discard the incomplete import \(id.uuidString). Unknown or unsafe contents are left untouched."
            case .discardPendingSelection: "Discard the uncommitted preference. The last committed choice is not changed."
            }
        }
    }

    struct RecoveryConfirmation: Identifiable {
        let id = UUID()
        let action: RecoveryAction
        let session: UUID
    }

    func recoveryConfirmation(_ action: RecoveryAction) -> RecoveryConfirmation? {
        guard canUseLibrary, let session = imageSelectionSession, recoveryTargetExists(action) else { return nil }
        return RecoveryConfirmation(action: action, session: session)
    }

    private func recoveryTargetExists(_ action: RecoveryAction) -> Bool {
        guard let libraryInventory else { return false }
        switch action {
        case .trash(let id): return libraryInventory.entries.contains { $0.id == id }
        case .restore(let id), .purge(let id): return libraryInventory.trashedIDs.contains(id)
        case .discardStage(let id): return libraryInventory.abandonedStageIDs.contains(id)
        case .discardPendingSelection: return libraryInventory.pendingSelectionRecovery
        }
    }

    func confirmRecovery(_ confirmation: RecoveryConfirmation) {
        guard imageSelectionSession == confirmation.session,
              canUseLibrary, !imageQueue.isBusy,
              recoveryTargetExists(confirmation.action) else { return }
        switch confirmation.action {
        case .trash(let id):
            if imageSource == .installedPack(id) {
                // Do not keep presenting a pack whose selection may be
                // cleared before the move. Even on failure, stay built-in
                // until the user explicitly restores the saved choice.
                do {
                    runtime.setCatalog(try CompanionPreviewAssets.catalogue())
                    imageSource = .builtIn
                    imageMessage = ""
                    updatePresentation()
                } catch {
                    libraryMessage = "Unable to restore default. Trash operation not started."
                    return
                }
            }
            runLibrary(.trash(id))
        case .restore(let id): runLibrary(.restoreTrash(id))
        case .purge(let id): runLibrary(.purgeTrash(id))
        case .discardStage(let id): runLibrary(.discardStage(id))
        case .discardPendingSelection: runLibrary(.discardPendingSelection)
        }
    }

    private func restoreLibraryIfNeeded() {
        guard libraryNeedsRestore, !libraryBusy, imageSelectionSession != nil else { return }
        guard !imageQueue.isBusy else {
            libraryNeedsRestore = false
            libraryMessage = "Image worker still finishing. Restore saved choice manually."
            return
        }
        runLibrary(.restoreSelection)
    }

    private func runLibrary(_ request: PreviewPackLibrary.Request) {
        guard canUseLibrary, let root = libraryRoot, let session = imageSelectionSession else { return }
        guard !imageQueue.isBusy else {
            libraryMessage = "Image worker still finishing. Try again."
            return
        }
        libraryNeedsRestore = false
        // Explicit refresh and mutations invalidate every cached preview.
        // Selection/thumbnail requests may accumulate only current IDs.
        switch request {
        case .thumbnail, .select, .restoreSelection: break
        default: libraryThumbnails.removeAll()
        }
        libraryBusy = true
        libraryMessage = "Working with character library…"
        // A durable operation can commit after hide/stop. Hold the slot
        // until actual worker exit and fence UI publication independently.
        let worker = Task.detached(priority: .userInitiated) {
            try PreviewPackLibrary.perform(request, root: root)
        }
        Task { @MainActor [weak self] in
            let result = await worker.result
            guard let self else { return }
            self.libraryBusy = false
            guard self.imageSelectionSession == session else {
                if self.started {
                    self.libraryNeedsRestore = true
                    self.restoreLibraryIfNeeded()
                }
                return
            }
            switch result {
            case .success(let output):
                self.libraryInventory = output.inventory
                let validIDs = Set(output.inventory?.entries.filter { $0.name != nil }.map(\.id) ?? [])
                self.libraryThumbnails = self.libraryThumbnails.filter { validIDs.contains($0.key) }
                if let thumbnail = output.thumbnail, validIDs.contains(thumbnail.id),
                   self.libraryThumbnails[thumbnail.id] != nil ||
                    self.libraryThumbnails.count < PreviewPackThumbnail.maximumCount {
                    self.libraryThumbnails[thumbnail.id] = thumbnail.image
                }
                self.libraryMessage = output.message
                if let selection = output.selection {
                    do {
                        switch selection {
                        case .installed(let id, let catalogue):
                            self.runtime.setCatalog(catalogue)
                            self.imageSource = .installedPack(id)
                        case .builtIn, .unavailable:
                            self.runtime.setCatalog(try CompanionPreviewAssets.catalogue())
                            self.imageSource = .builtIn
                        }
                        self.imageMessage = ""
                        self.updatePresentation()
                    } catch {
                        self.libraryMessage = "Saved choice updated, but preview could not display it."
                    }
                }
            case .failure:
                self.libraryInventory = nil
                self.libraryThumbnails.removeAll()
                self.libraryMessage = "Library operation failed. Current display retained; refresh or restore saved choice."
            }
        }
    }

    func appLaunched() {
        _ = stopIfConflictingApplicationRunning()
    }

    /// The workspace launch notification may have been missed during sleep.
    private func stopIfConflictingApplicationRunning() -> Bool {
        guard started, let conflict = conflictingApplication() else { return false }
        stop()
        message = "Preview stopped because \(conflict) is running."
        return true
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        if !value, stopIfConflictingApplicationRunning() { return }
        reconcile()
    }

    func accessibilityChanged() { reconcile() }

    @objc private func activateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
    }

    private func reconcile() {
        reconcileImageSession()
        let old = transition
        refresh?.cancel()
        refresh = nil
        revision = UUID()
        let expected = revision
        let widget = started && !sleeping && showCPU
        let asleep = sleeping
        runtime.setMode(automatic ? .automatic : .manual(manualRate))
        runtime.setPresentation(
            enabled: started, visible: showCharacter, awake: !sleeping,
            reduceMotion: freeze || systemReduceMotion()
        )
        // setMode/setPresentation already invalidate the input when actual
        // automatic demand changes. Keep EMA and consumed sample identities
        // across presentation-only changes. A changed sampler epoch reseeds
        // the policy on the next accepted observation.
        runtime.setLocalEventsEnabled(listenToLocalEvents)
        reconcileLocalSubscription()
        let companion = runtime.wantsHostCPU
        if !widget { cpuText = "" }
        updatePresentation()
        let sampler = sampler
        let waitForNextPoll = waitForNextPoll
        transition = Task { @MainActor [weak self] in
            await old?.value
            await sampler.reconcileDemand(widget: widget, companion: companion, sleeping: asleep)
            guard let self, self.revision == expected else { return }
            guard widget || companion else { return }
            self.refresh = Task { @MainActor [weak self] in
                var firstIteration = true
                while !Task.isCancelled {
                    guard self?.revision == expected else { return }
                    await self?.refreshOnce(widget: widget, companion: companion,
                        revision: expected, force: firstIteration)
                    firstIteration = false
                    guard !Task.isCancelled, self?.revision == expected else { return }
                    let plan = await sampler.refreshPlan()
                    guard !Task.isCancelled, self?.revision == expected,
                          plan.acquisitionDelay != nil else { return }
                    // Both leases share one deadline. A pending delivery must
                    // not sleep through a fresh cache window.
                    // Do not bind self strongly across the idle wait.
                    do { try await waitForNextPoll(plan.nextHostDelay(otherWidgetsSeconds: 30)) }
                    catch { return }
                }
            }
        }
    }

    private func reconcileLocalSubscription() {
        let session = runtime.localEventSession
        guard subscribedSession != session else { return }
        localSubscription?.stop()
        localSubscription = nil
        subscribedSession = session
        guard let session else { return }
        // Headless tests use explicit synthetic delivery, not the system bus.
        guard !allowHeadlessPresentation else { return }
        let subscription = PreviewLocalNotificationSubscription(session: session) { [weak self] id, kind, object in
            self?.receiveLocalNotification(session: id, kind: kind, object: object)
        }
        localSubscription = subscription
        subscription.start()
    }

    var localNotificationSession: UUID? { subscribedSession }

    @discardableResult
    func receiveLocalNotification(session: UUID, kind: CompanionLocalEventIngress.Kind,
                                  object: Any?) -> CompanionLocalEventIngress.Outcome? {
        guard subscribedSession == session else { return nil }
        return runtime.receiveLocalEvent(session: session, kind: kind) {
            PreviewLocalNotificationSubscription.boundedPayload(object)
        }
    }

    private func refreshOnce(widget: Bool, companion: Bool, revision expected: UUID,
                             force: Bool) async {
        let firstPlan = await sampler.refreshPlan()
        guard revision == expected, !Task.isCancelled else { return }
        if widget && (force || firstPlan.requiresRefresh(.widget)) {
            do {
                let sample = try await sampler.sample(for: HostCPUConsumer.widget)
                guard revision == expected, !Task.isCancelled else { return }
                cpuText = "Total CPU \(Int(sample.percentage.rounded()))%"
            } catch is CancellationError {
                // Revoked lease is not a counter failure.
            } catch {
                guard revision == expected, !Task.isCancelled else { return }
                cpuText = "Total CPU unavailable"
            }
        }
        // Re-read after the widget: it might have just acquired a new
        // observation that the companion has not yet consumed.
        let secondPlan = await sampler.refreshPlan()
        guard revision == expected, !Task.isCancelled else { return }
        if companion && (force || secondPlan.requiresRefresh(.companion)),
           let request = runtime.beginCPURequest() {
            do {
                let sample = try await sampler.sample(for: HostCPUConsumer.companion)
                guard revision == expected, !Task.isCancelled else { return }
                runtime.acceptCPU(request, id: sample.id, epoch: sample.epoch,
                    capturedAt: sample.capturedAt, hostPercentage: sample.percentage)
            } catch is CancellationError {
                // Revoked lease is not a counter failure.
            } catch {
                guard revision == expected, !Task.isCancelled else { return }
                runtime.cpuUnavailable(request)
            }
        }
        guard revision == expected, !Task.isCancelled else { return }
        updatePresentation()
    }

    private func updatePresentation() {
        state = runtime.state
        effectiveRate = runtime.rate.factor
        guard let button = item?.button else { return }
        button.title = cpuText.isEmpty ? "" : " " + cpuText
        button.imagePosition = cpuText.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = cpuText.isEmpty ? "SchneeBar Companion Preview" : cpuText
        button.setAccessibilityLabel("SchneeBar Companion Preview"
            + (cpuText.isEmpty ? "" : ", " + cpuText))
    }

    isolated deinit {
        localSubscription?.stop()
        imageQueue.cancel()
        refresh?.cancel()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        let pending = transition
        let sampler = sampler
        // Drain demand changes without retaining the dying model, then revoke
        // both consumers. Renderer deinit independently cancels its frame task.
        Task {
            await pending?.value
            await sampler.reconcileDemand(widget: false, companion: false, sleeping: true)
        }
    }
}
