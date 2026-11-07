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
    private let workspaceNotificationCenter: NotificationCenter
    private var refreshTask: Task<Void, Never>?
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
        widgetEngine = WidgetEngine(providers: [
            ClockWidgetProvider(),
            CPUWidgetProvider(),
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
        immediateActivityRefreshTask?.cancel()
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
        externalWidgetStartupCoordinator.handleSleep(
            model: runtimeModel
        )

        refreshTask?.cancel()
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

            await engine.setConfiguration(model.configuration)
            guard isCurrentRuntime(generation) else { return }

            model.descriptors = await engine.descriptors()
            guard isCurrentRuntime(generation) else { return }
            widgetRuntimeIsConfigured = true

            model.onConfigurationChanged = { [weak self, engine] configuration in
                Task { @MainActor [weak self] in
                    guard let self, isCurrentRuntime(generation) else { return }

                    await engine.setConfiguration(configuration)
                    guard isCurrentRuntime(generation) else { return }

                    _ = await engine.refreshDue()
                    await applyCurrentPresentation(from: engine, generation: generation)
                }
            }

            if forceRefreshOnStart {
                activityRefreshIsPending = false
                _ = await engine.refreshAll()
                await applyCurrentPresentation(from: engine, generation: generation)
            } else if activityRefreshIsPending {
                refreshActivityNow()
            }

            while !Task.isCancelled, isCurrentRuntime(generation) {
                _ = await engine.refreshDue()
                await applyCurrentPresentation(from: engine, generation: generation)

                let delay = await engine.secondsUntilNextRefresh(maximum: 30)
                guard isCurrentRuntime(generation) else { return }
                let sleepSeconds = max(1, Int64(delay.rounded(.up)))

                do {
                    try await Task.sleep(for: .seconds(sleepSeconds))
                } catch {
                    return
                }
            }
        }
    }

    private func isCurrentRuntime(_ generation: WidgetRuntimeLifecycle.Generation) -> Bool {
        activeRuntimeGeneration == generation && runtimeLifecycle.isCurrent(generation)
    }

    private func applyCurrentPresentation(
        from engine: WidgetEngine,
        generation: WidgetRuntimeLifecycle.Generation
    ) async {
        let presentation = await engine.currentPresentation()
        guard isCurrentRuntime(generation) else { return }
        let diagnostics = Dictionary(
            presentation.diagnostics
                .filter { runtimeModel.configuration.isEnabled($0.descriptor) }
                .map { ($0.descriptor.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        apply(snapshots: presentation.snapshots, diagnostics: diagnostics)
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
