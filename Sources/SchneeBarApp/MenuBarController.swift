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
    private let externalWidgetRegistrar: ExternalWidgetStartupRegistrar?
    private let widgetEngine: WidgetEngine
    private let workspaceNotificationCenter: NotificationCenter
    private var refreshTask: Task<Void, Never>?
    private var immediateActivityRefreshTask: Task<Void, Never>?
    private var widgetRuntimeIsConfigured = false
    private var externalWidgetStartupFinished = false
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
        self.externalWidgetRegistrar = externalWidgetRegistrar
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

            let snapshots = await engine.orderedVisibleSnapshots()
            guard isCurrentRuntime(generation) else { return }
            apply(snapshots: snapshots)
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

            if !externalWidgetStartupFinished,
               let externalWidgetRegistrar
            {
                model.externalWidgetStartupHealth = .loading

                do {
                    let result = try await externalWidgetRegistrar
                        .loadAndRegister(in: engine)
                    guard isCurrentRuntime(generation) else { return }

                    switch result {
                    case let .loaded(widgetCount):
                        model.externalWidgetStartupHealth = .loaded(
                            widgetCount: widgetCount
                        )
                    case let .unavailable(reason):
                        model.externalWidgetStartupHealth = .unavailable(
                            reason
                        )
                    }
                    externalWidgetStartupFinished = true
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrentRuntime(generation) else { return }
                    model.externalWidgetStartupHealth = .unavailable(
                        .unknown
                    )
                    externalWidgetStartupFinished = true
                }
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

                    let snapshots = await engine.refreshDue()
                    guard isCurrentRuntime(generation) else { return }
                    apply(snapshots: snapshots)
                }
            }

            if forceRefreshOnStart {
                activityRefreshIsPending = false
                let snapshots = await engine.refreshAll()
                guard isCurrentRuntime(generation) else { return }
                apply(snapshots: snapshots)
            } else if activityRefreshIsPending {
                refreshActivityNow()
            }

            while !Task.isCancelled, isCurrentRuntime(generation) {
                let snapshots = await engine.refreshDue()
                guard isCurrentRuntime(generation) else { return }
                apply(snapshots: snapshots)

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

    private func apply(snapshots: [WidgetSnapshot]) {
        runtimeModel.snapshots = snapshots

        guard let button = statusItem.button else { return }
        let labels = snapshots.prefix(3).map { snapshot in
            let representation = runtimeModel.configuration.representation(for: snapshot)
            return snapshot.content(for: representation).text
        }

        button.title = labels.isEmpty ? "" : " " + labels.joined(separator: "  ")
        button.imagePosition = labels.isEmpty ? .imageOnly : .imageLeading
        button.setAccessibilityLabel(
            labels.isEmpty
                ? "SchneeBar"
                : "SchneeBar, " + labels.joined(separator: ", ")
        )
    }
}
