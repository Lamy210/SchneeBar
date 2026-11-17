import AppKit
import Combine
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionFeature
import SchneeBarSystemProvider

/// Developer preview only. No preferences, network, login items or GitHub.
@MainActor
final class CompanionPreviewModel: NSObject, ObservableObject {
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

    private let sampler: HostCPUSampler
    private let isBarRunning: @MainActor () -> Bool
    private let makeStatusItem: @MainActor () -> NSStatusItem?
    private let systemReduceMotion: @MainActor () -> Bool
    private let allowHeadlessPresentation: Bool
    private let waitForNextPoll: @Sendable (Duration) async throws -> Void
    private var item: NSStatusItem?
    private var fallback: NSImage? {
        NSImage(systemSymbolName: "snowflake", accessibilityDescription: "SchneeBar Preview")
    }
    private lazy var runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(
        onFrame: { [weak self] image in self?.item?.button?.image = image },
        onClear: { [weak self] in
            guard let self else { return }
            self.item?.button?.image = self.fallback
        }
    ))
    private var transition: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var revision = UUID()
    private var sleeping = false

    init(
        sampler: HostCPUSampler = HostCPUSampler(),
        isBarRunning: @escaping @MainActor () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.lamy.schneebar").isEmpty
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
        }
    ) {
        self.sampler = sampler
        self.isBarRunning = isBarRunning
        self.makeStatusItem = makeStatusItem
        self.systemReduceMotion = systemReduceMotion
        self.allowHeadlessPresentation = allowHeadlessPresentation
        self.waitForNextPoll = waitForNextPoll
        super.init()
    }

    func start() {
        guard !started else { return }
        guard !isBarRunning() else {
            message = "Quit SchneeBar before starting the isolated preview."
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
        started = true
        message = ""
        reconcile()
    }

    func stop() {
        guard started else { return }
        started = false
        reconcile()
        runtime.setCatalog(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func appLaunched() {
        if started && isBarRunning() {
            stop()
            message = "Preview stopped because SchneeBar launched."
        }
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        reconcile()
    }

    func accessibilityChanged() { reconcile() }

    @objc private func activateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
    }

    private func reconcile() {
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
