import AppKit
import SchneeBarPreferences
import SwiftUI

@main
struct SchneeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.runtimeModel)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtimeModel = WidgetRuntimeModel(
        preferencesStore: UserDefaultsWidgetPreferencesStore()
    )

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(runtimeModel: runtimeModel)
    }
}
