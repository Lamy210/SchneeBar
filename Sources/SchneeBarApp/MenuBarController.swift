import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "snowflake",
                accessibilityDescription: "SchneeBar"
            )
            button.toolTip = "SchneeBar"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverRootView())
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
}
