import AppKit
import Combine
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionFeature
import SchneeBarCompanionEvents
import SchneeBarSystemProvider
import UniformTypeIdentifiers

/// Developer preview only. No preferences, network, login items or GitHub.
@MainActor
final class CompanionPreviewModel: NSObject, ObservableObject {
    enum ImageSource: Equatable { case builtIn, selectedFile }
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
        imageQueue: CompanionImportQueue<URL, CompanionAssetCatalog>? = nil
    ) {
        self.imageQueue = imageQueue ?? CompanionSingleFileImporter.makeQueue()
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
        reconcile()
    }

    func stop() {
        guard started else { return }
        started = false
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
        guard let session = imageSelectionSession else { return }
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
        guard imageSelectionSession == session else { return }
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
        guard imageSelectionSession != nil else { return }
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
        } else if imageSelectionSession != nil {
            imageSelectionSession = nil
            imageQueue.cancel()
            imageImportPending = false
            imageMessage = ""
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
                while !Task.isCancelled {
                    guard self?.revision == expected else { return }
                    await self?.refreshOnce(widget: widget, companion: companion, revision: expected)
                    guard !Task.isCancelled, self?.revision == expected else { return }
                    // Match the cache's monotonic deadline even if this
                    // generation started with a cached observation.
                    let consumer: HostCPUConsumer = widget ? .widget : .companion
                    let delay = await sampler.delayUntilNextAcquisition(for: consumer)
                    guard !Task.isCancelled, self?.revision == expected,
                          let delay else { return }
                    // Do not bind self strongly across deadline query or idle wait.
                    do { try await waitForNextPoll(max(.milliseconds(50), delay)) }
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

    private func refreshOnce(widget: Bool, companion: Bool, revision expected: UUID) async {
        if widget {
            do {
                let sample = try await sampler.sample(for: HostCPUConsumer.widget)
                guard revision == expected, !Task.isCancelled else { return }
                cpuText = "Total CPU \(Int(sample.percentage.rounded()))%"
            } catch {
                guard revision == expected, !Task.isCancelled else { return }
                cpuText = "Total CPU unavailable"
            }
        }
        if companion, let request = runtime.beginCPURequest() {
            do {
                let sample = try await sampler.sample(for: HostCPUConsumer.companion)
                guard revision == expected, !Task.isCancelled else { return }
                runtime.acceptCPU(request, id: sample.id, epoch: sample.epoch,
                    capturedAt: sample.capturedAt, hostPercentage: sample.percentage)
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
