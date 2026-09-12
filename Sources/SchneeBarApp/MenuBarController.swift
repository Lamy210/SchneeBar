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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        runtimeModel = WidgetRuntimeModel()
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

        startWidgetRefreshLoop()
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

    private func startWidgetRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let snapshots = await widgetEngine.refreshDue()
                apply(snapshots: snapshots)

                let delay = await widgetEngine.secondsUntilNextRefresh(maximum: 30)
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
            let representation: WidgetRepresentationKind = snapshot.severity >= .critical
                ? .critical
                : .compact
            return snapshot.content(for: representation).text
        }

        button.title = labels.isEmpty ? "" : " " + labels.joined(separator: "  ")
        button.imagePosition = labels.isEmpty ? .imageOnly : .imageLeading
        button.accessibilityLabel = labels.isEmpty
            ? "SchneeBar"
            : "SchneeBar, " + labels.joined(separator: ", ")
    }
}
