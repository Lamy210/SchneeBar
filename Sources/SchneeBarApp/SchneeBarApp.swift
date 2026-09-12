import AppKit
import SchneeBarGitHub
import SchneeBarGitHubKeychain
import SchneeBarGitHubProfiles
import SchneeBarPreferences
import SwiftUI

@main
struct SchneeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                model: appDelegate.runtimeModel,
                githubModel: appDelegate.githubRuntimeModel
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtimeModel = WidgetRuntimeModel(
        preferencesStore: UserDefaultsWidgetPreferencesStore()
    )

    let githubRuntimeModel: GitHubConnectionsRuntimeModel

    private var menuBarController: MenuBarController?

    override init() {
        let credentialStore = KeychainGitHubCredentialStore()
        let profileStore = ApplicationSupportGitHubConnectionProfileStore()
        let sessionCoordinator = GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        )
        githubRuntimeModel = GitHubConnectionsRuntimeModel(
            profileStore: profileStore,
            sessionCoordinator: sessionCoordinator
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(runtimeModel: runtimeModel)

        Task { @MainActor [weak self] in
            await self?.githubRuntimeModel.load()
        }
    }
}
