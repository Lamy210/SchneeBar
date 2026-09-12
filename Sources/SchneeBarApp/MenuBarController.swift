import AppKit
import SchneeBarActivityFeature
import SchneeBarCore
import SchneeBarSystemProvider
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let runtimeModel: WidgetRuntimeModel
    private let widgetEngine: WidgetEngine
    private var refreshTask: Task<Void, Never>?

    init(runtimeModel: WidgetRuntimeModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        self.runtimeModel = runtimeModel
        widgetEngine = WidgetEngine(providers: [
            ClockWidgetProvider(),
            CPUWidgetProvider(),
            ActivityWidgetProvider(loadItems: { [] }),
        ])
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
            rootView: PopoverRootView(model: runtimeModel)
        )

        configureAndStartWidgetRuntime()
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

    private func configureAndStartWidgetRuntime() {
        refreshTask?.cancel()
        let engine = widgetEngine
        let model = runtimeModel

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await model.loadPreferences()
            await engine.setConfiguration(model.configuration)
            model.descriptors = await engine.descriptors()

            model.onConfigurationChanged = { [weak self, engine] configuration in
                Task { @MainActor [weak self] in
                    await engine.setConfiguration(configuration)
                    let snapshots = await engine.refreshDue()
                    self?.apply(snapshots: snapshots)
                }
            }

            while !Task.isCancelled {
                let snapshots = await engine.refreshDue()
                apply(snapshots: snapshots)

                let delay = await engine.secondsUntilNextRefresh(maximum: 30)
                let sleepSeconds = max(1, Int64(delay.rounded(.up)))

                do {
                    try await Task.sleep(for: .seconds(sleepSeconds))
                } catch {
                    return
                }
            }
        }
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
