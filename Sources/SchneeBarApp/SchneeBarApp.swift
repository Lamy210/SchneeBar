import AppKit
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
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
        let workflowRunService = GitHubWorkflowRunService(
            sessionCoordinator: sessionCoordinator
        )
        let activityProvider = GitHubActivityProvider(
            workflowRunLoader: workflowRunService
        )
        githubRuntimeModel = GitHubConnectionsRuntimeModel(
            profileStore: profileStore,
            sessionCoordinator: sessionCoordinator,
            activityProvider: activityProvider
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let githubRuntimeModel = githubRuntimeModel
        menuBarController = MenuBarController(
            runtimeModel: runtimeModel,
            loadActivityItems: {
                try await githubRuntimeModel.loadActivityItems()
            }
        )

        githubRuntimeModel.onActivitySourceChanged = { [weak self] in
            self?.menuBarController?.refreshActivityNow()
        }

        Task { @MainActor [weak self] in
            await self?.githubRuntimeModel.load()
        }
    }
}
