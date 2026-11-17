import AppKit
import SchneeBarActivityFeature
import SchneeBarCore
import SchneeBarSystemProvider
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private static let activityWidgetID: WidgetID = "developer.activity"

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let runtimeModel: WidgetRuntimeModel
    private let activityRuntimeModel: ActivityRuntimeModel
    private let externalWidgetStartupCoordinator: ExternalWidgetStartupCoordinator
    private let widgetEngine: WidgetEngine
    private let cpuSampler: HostCPUSampler
    private let cpuProvider: CPUWidgetProvider
    private var configurationTask: Task<Void, Never>?
    private var configurationRevision = UUID()
    private var cpuDemandEnabled = false
    private let workspaceNotificationCenter: NotificationCenter
    private var refreshTask: Task<Void, Never>?
    private var refreshSleepTask: Task<Void, Never>?
    private var immediateActivityRefreshTask: Task<Void, Never>?
    private var widgetRuntimeIsConfigured = false
    private var activityRefreshIsPending = false
    private var runtimeLifecycle = WidgetRuntimeLifecycle()
    private var activeRuntimeGeneration: WidgetRuntimeLifecycle.Generation?

    init(
        runtimeModel: WidgetRuntimeModel,
        activityRuntimeModel: ActivityRuntimeModel,
        externalWidgetRegistrar: ExternalWidgetStartupRegistrar? = nil,
        loadActivitySnapshot:
            @escaping @Sendable () async throws -> ActivityAggregateSnapshot
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        self.runtimeModel = runtimeModel
        self.activityRuntimeModel = activityRuntimeModel
        externalWidgetStartupCoordinator = ExternalWidgetStartupCoordinator(
            registrar: externalWidgetRegistrar
        )
        let sampler = HostCPUSampler()
        let provider = CPUWidgetProvider(sampler: sampler)
        cpuSampler = sampler
        cpuProvider = provider
        widgetEngine = WidgetEngine(providers: [
            ClockWidgetProvider(),
            provider,
            ActivityWidgetProvider(loadSnapshot: loadActivitySnapshot),
        ])
        workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "snowflake",
                accessibilityDescription: "SchneeBar"
            )
            button.imagePosition = .imageLeading
            button.toolTip = "SchneeBar"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                model: runtimeModel,
                activityModel: activityRuntimeModel
            )
        )

        observeWorkspacePowerEvents()
        configureAndStartWidgetRuntime()
    }

    deinit {
        refreshTask?.cancel()
        refreshSleepTask?.cancel()
        immediateActivityRefreshTask?.cancel()
        let pending = configurationTask
        pending?.cancel()
        // Drain earlier transitions before the final suspend, without retaining self.
        let sampler = cpuSampler
        Task {
            await pending?.value
            await sampler.reconcileDemand(widget: false, companion: false, sleeping: true)
        }
        workspaceNotificationCenter.removeObserver(self)
    }

    func refreshActivityNow() {
        guard widgetRuntimeIsConfigured,
              let generation = activeRuntimeGeneration,
              runtimeLifecycle.isCurrent(generation)
        else {
            activityRefreshIsPending = true
            return
        }

        activityRefreshIsPending = false
        immediateActivityRefreshTask?.cancel()
        let engine = widgetEngine

        immediateActivityRefreshTask = Task { @MainActor [weak self] in
            guard let self, isCurrentRuntime(generation) else { return }

            let descriptors = await engine.descriptors()
            guard isCurrentRuntime(generation),
                  let activityDescriptor = descriptors.first(where: {
                      $0.id == Self.activityWidgetID
                  })
            else {
                return
            }

            let configuration = await engine.currentConfiguration()
            guard isCurrentRuntime(generation),
                  configuration.isEnabled(activityDescriptor)
            else {
                return
            }

            _ = await engine.refresh(id: Self.activityWidgetID)
            guard isCurrentRuntime(generation) else { return }

            await applyCurrentPresentation(from: engine, generation: generation)
        }
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private func observeWorkspacePowerEvents() {
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc
    private func workspaceWillSleep(_ notification: Notification) {
        guard !runtimeLifecycle.isSleeping else { return }

        runtimeLifecycle.willSleep()
        activeRuntimeGeneration = nil
        widgetRuntimeIsConfigured = false
        _ = enqueueConfiguration(nil, sleeping: true)
        externalWidgetStartupCoordinator.handleSleep(
            model: runtimeModel
        )

        refreshTask?.cancel()
        refreshSleepTask?.cancel()
        refreshTask = nil
        immediateActivityRefreshTask?.cancel()
        immediateActivityRefreshTask = nil
    }

    @objc
    private func workspaceDidWake(_ notification: Notification) {
        guard let generation = runtimeLifecycle.didWake() else { return }

        configureAndStartWidgetRuntime(
            loadPreferences: false,
            forceRefreshOnStart: true,
            generation: generation
        )
    }

    private func configureAndStartWidgetRuntime(
        loadPreferences: Bool = true,
        forceRefreshOnStart: Bool = false,
        generation providedGeneration: WidgetRuntimeLifecycle.Generation? = nil
    ) {
        let generation: WidgetRuntimeLifecycle.Generation
        if let providedGeneration {
            guard runtimeLifecycle.isCurrent(providedGeneration) else { return }
            generation = providedGeneration
        } else {
            guard let newGeneration = runtimeLifecycle.beginRuntime() else { return }
            generation = newGeneration
        }

        refreshTask?.cancel()
        refreshSleepTask?.cancel()
        activeRuntimeGeneration = generation

        let engine = widgetEngine
        let model = runtimeModel

        refreshTask = Task { @MainActor [weak self] in
            guard let self, isCurrentRuntime(generation) else { return }

            if loadPreferences {
                await model.loadPreferences()
                guard isCurrentRuntime(generation) else { return }
            }

            do {
                try await externalWidgetStartupCoordinator.runIfNeeded(
                    in: engine,
                    model: model,
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.isCurrentRuntime(generation)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }

            let descriptors = await engine.descriptors()
            guard isCurrentRuntime(generation) else { return }

            model.onConfigurationChanged = { [weak self, engine] configuration in
                guard let self, isCurrentRuntime(generation) else { return }
                let transition = enqueueConfiguration(configuration, sleeping: false)
                let revision = configurationRevision
                Task { @MainActor [weak self] in
                    await transition.value
                    guard let self, isCurrentRuntime(generation),
                          configurationRevision == revision else { return }

                    await refreshScheduledWidgets(generation: generation, revision: revision)
                    await applyCurrentPresentation(from: engine, generation: generation)
                }
            }

            let initial = enqueueConfiguration(model.configuration, sleeping: false)
            model.descriptors = descriptors
            await initial.value
            await configurationTask?.value
            guard isCurrentRuntime(generation), !Task.isCancelled else { return }
            widgetRuntimeIsConfigured = true

            if forceRefreshOnStart {
                activityRefreshIsPending = false
                await refreshScheduledWidgets(
                    generation: generation, revision: configurationRevision, forceOtherWidgets: true
                )
                await applyCurrentPresentation(from: engine, generation: generation)
            } else if activityRefreshIsPending {
                refreshActivityNow()
            }

            while !Task.isCancelled, isCurrentRuntime(generation) {
                let revision = configurationRevision
                await configurationTask?.value
                guard isCurrentRuntime(generation), !Task.isCancelled else { return }
                guard configurationRevision == revision else { continue }
                await refreshScheduledWidgets(generation: generation, revision: revision)
                await applyCurrentPresentation(from: engine, generation: generation)

                let otherDelay = await engine.secondsUntilNextRefresh(
                    maximum: 30, excluding: [cpuProvider.descriptor.id]
                )
                let cpuDelay = await cpuSampler.delayUntilNextAcquisition(for: .widget)
                guard isCurrentRuntime(generation), !Task.isCancelled else { return }
                guard configurationRevision == revision else { continue }
                // Keep the existing one-second floor for ordinary widgets;
                // allow the CPU's subsecond remainder after a bootstrap.
                let delay = min(.seconds(max(1, otherDelay)), cpuDelay ?? .seconds(30))
                let sleeper = Task {
                    try? await Task.sleep(for: max(.milliseconds(50), delay))
                }
                refreshSleepTask = sleeper
                await sleeper.value
                guard isCurrentRuntime(generation), !Task.isCancelled else { return }
                refreshSleepTask = nil
            }
        }
    }

    /// The CPU clock belongs to the sampler, not WidgetEngine's wall-clock
    /// attemptedAt. Both paths share the existing refresh loop and actor.
    private func refreshScheduledWidgets(
        generation: WidgetRuntimeLifecycle.Generation, revision: UUID,
        forceOtherWidgets: Bool = false
    ) async {
        guard isCurrentRuntime(generation), configurationRevision == revision,
              !Task.isCancelled else { return }
        let cpuID = cpuProvider.descriptor.id
        if cpuDemandEnabled,
           await cpuSampler.delayUntilNextAcquisition(for: .widget) == .zero,
           isCurrentRuntime(generation), configurationRevision == revision, !Task.isCancelled {
            _ = await widgetEngine.refreshIfEnabled(id: cpuID)
        }
        guard isCurrentRuntime(generation), configurationRevision == revision,
              !Task.isCancelled else { return }
        if forceOtherWidgets {
            _ = await widgetEngine.refreshAll(excluding: [cpuID])
        } else {
            _ = await widgetEngine.refreshDue(excluding: [cpuID])
        }
    }

    /// Submit every transition in main-actor order; the FIFO contains only
    /// short configuration calls, never a counter acquisition or widget refresh.
    @discardableResult
    private func enqueueConfiguration(
        _ configuration: SchneeBarCore.WidgetConfiguration?, sleeping: Bool
    ) -> Task<Void, Never> {
        let previous = configurationTask
        let sampler = cpuSampler
        let engine = widgetEngine
        let descriptor = cpuProvider.descriptor
        let enabled = !sleeping && (configuration?.isEnabled(descriptor) ?? false)
        let resetCPU = sleeping || enabled != cpuDemandEnabled
        cpuDemandEnabled = enabled
        configurationRevision = UUID()
        refreshSleepTask?.cancel()
        if resetCPU {
            // Do not expose a last-known-good CPU value across a demand epoch.
            let remaining = runtimeModel.snapshots.filter { $0.descriptor.id != descriptor.id }
            var diagnostics = runtimeModel.diagnosticsByWidgetID
            diagnostics.removeValue(forKey: descriptor.id)
            apply(snapshots: remaining, diagnostics: diagnostics)
        }

        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await sampler.reconcileDemand(widget: enabled, companion: false, sleeping: sleeping)
            if let configuration {
                await engine.setConfiguration(
                    configuration, invalidatingRuntimeOf: resetCPU ? descriptor.id : nil
                )
            } else if resetCPU {
                await engine.invalidateRuntime(id: descriptor.id)
            }
        }
        configurationTask = task
        return task
    }

    private func isCurrentRuntime(_ generation: WidgetRuntimeLifecycle.Generation) -> Bool {
        activeRuntimeGeneration == generation && runtimeLifecycle.isCurrent(generation)
    }

    private func applyCurrentPresentation(
        from engine: WidgetEngine,
        generation: WidgetRuntimeLifecycle.Generation
    ) async {
        let revision = configurationRevision
        await configurationTask?.value
        guard isCurrentRuntime(generation), configurationRevision == revision else { return }
        let presentation = await engine.currentPresentation()
        guard isCurrentRuntime(generation), configurationRevision == revision else { return }
        let diagnostics = Dictionary(
            presentation.diagnostics
                .filter { runtimeModel.configuration.isEnabled($0.descriptor) }
                .map { ($0.descriptor.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        apply(
            snapshots: presentation.snapshots.filter {
                runtimeModel.configuration.isEnabled($0.descriptor)
            },
            diagnostics: diagnostics
        )
    }

    private func apply(
        snapshots: [WidgetSnapshot],
        diagnostics: [WidgetID: WidgetRuntimeDiagnostic]
    ) {
        runtimeModel.snapshots = snapshots
        runtimeModel.diagnosticsByWidgetID = diagnostics

        guard let button = statusItem.button else { return }
        let displayedIDs = Set(snapshots.map(\.descriptor.id))
        let unavailableLabels = diagnostics.values
            .filter {
                $0.indicatesUnavailableReading
                    && !displayedIDs.contains($0.descriptor.id)
            }
            .sorted {
                if $0.descriptor.defaultOrder != $1.descriptor.defaultOrder {
                    return $0.descriptor.defaultOrder < $1.descriptor.defaultOrder
                }
                return $0.descriptor.id.rawValue < $1.descriptor.id.rawValue
            }
            .map { "\($0.descriptor.displayName) unavailable" }
        let snapshotLabels = snapshots.map { snapshot in
            let representation = runtimeModel.configuration.representation(for: snapshot)
            let text = snapshot.content(for: representation).text
            let isStale = diagnostics[snapshot.descriptor.id]?
                .indicatesStaleReading(for: snapshot) == true
            return isStale ? "\(text) (stale)" : text
        }
        // Errors must be visible even when other widgets occupy the three
        // available status-bar positions.
        let labels = Array((unavailableLabels + snapshotLabels).prefix(3))

        button.title = labels.isEmpty ? "" : " " + labels.joined(separator: "  ")
        button.imagePosition = labels.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = labels.isEmpty ? "SchneeBar" : labels.joined(separator: ", ")
        button.setAccessibilityLabel(
            labels.isEmpty
                ? "SchneeBar"
                : "SchneeBar, " + labels.joined(separator: ", ")
        )
    }
}
