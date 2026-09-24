import AppKit
import SchneeBarCore
import SchneeBarExternalWidgets
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
    let activityRuntimeModel = ActivityRuntimeModel()

    let githubRuntimeModel: GitHubConnectionsRuntimeModel
    private let workflowRunService: GitHubWorkflowRunService
    private let workflowRunMutationService: GitHubWorkflowRunMutationService
    private let workflowJobService: GitHubWorkflowJobService
    private let deliveryTimelineService: GitHubDeliveryTimelineService
    private let deploymentTimelineService: GitHubDeploymentTimelineService
    private let environmentCatalogService: GitHubEnvironmentCatalogService
    private let deliveryRecoveryNotifier: any DeliveryRecoveryNotifying

    private var menuBarController: MenuBarController?

    override init() {
        let credentialStore = KeychainGitHubCredentialStore()
        let profileStore = ApplicationSupportGitHubConnectionProfileStore()
        let sessionCoordinator = GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        )
        workflowRunService = GitHubWorkflowRunService(
            sessionCoordinator: sessionCoordinator
        )
        workflowRunMutationService = GitHubWorkflowRunMutationService(
            sessionCoordinator: sessionCoordinator
        )
        let reviewRequestService = GitHubReviewRequestService(
            sessionCoordinator: sessionCoordinator
        )
        let checkRunService = GitHubCheckRunService(
            sessionCoordinator: sessionCoordinator
        )
        workflowJobService = GitHubWorkflowJobService(
            sessionCoordinator: sessionCoordinator
        )
        deliveryTimelineService = GitHubDeliveryTimelineService(
            sessionCoordinator: sessionCoordinator
        )
        deploymentTimelineService = GitHubDeploymentTimelineService(
            sessionCoordinator: sessionCoordinator
        )
        environmentCatalogService = GitHubEnvironmentCatalogService(
            sessionCoordinator: sessionCoordinator
        )
        deliveryRecoveryNotifier = DeliveryRecoveryNotifier()
        let activityProvider = GitHubActivityProvider(
            workflowRunLoader: workflowRunService,
            reviewRequestLoader: reviewRequestService,
            checkRunLoader: checkRunService
        )
        let deliveryHistoryStore = ApplicationSupportDeliveryHistoryStore()
        githubRuntimeModel = GitHubConnectionsRuntimeModel(
            profileStore: profileStore,
            sessionCoordinator: sessionCoordinator,
            activityProvider: activityProvider,
            deliveryHistoryStore: deliveryHistoryStore
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let githubRuntimeModel = githubRuntimeModel
        let activityRuntimeModel = activityRuntimeModel
        let workflowRunService = workflowRunService
        let workflowRunMutationService = workflowRunMutationService
        let workflowJobService = workflowJobService
        let deliveryTimelineService = deliveryTimelineService
        let deploymentTimelineService = deploymentTimelineService
        let environmentCatalogService = environmentCatalogService
        let deliveryRecoveryNotifier = deliveryRecoveryNotifier
        let activityAggregator = ActivitySourceAggregator(
            sources: [
                ClosureActivitySource(id: "github") {
                    try await githubRuntimeModel.loadActivitySourceSnapshot()
                },
            ]
        )

        activityRuntimeModel.configureDetailLoader { item in
            try await githubRuntimeModel.loadActivityDetail(
                for: item,
                jobService: workflowJobService,
                timelineLoader: deliveryTimelineService,
                deploymentTimelineLoader: deploymentTimelineService,
                environmentCatalogLoader: environmentCatalogService
            )
        }

        activityRuntimeModel.configureDeliveryHistoryLoader { item in
            try await githubRuntimeModel.loadDeliveryHistory(
                for: item,
                workflowRunLoader: workflowRunService
            )
        }

        activityRuntimeModel.configureDetailActionHandler { item, action in
            try await githubRuntimeModel.performWorkflowRunAction(
                action,
                for: item,
                mutationService: workflowRunMutationService
            )
        }

        menuBarController = MenuBarController(
            runtimeModel: runtimeModel,
            activityRuntimeModel: activityRuntimeModel,
            externalWidgetRegistrar: .applicationSupport(),
            loadActivitySnapshot: {
                let snapshot = try await activityAggregator.load()
                await activityRuntimeModel.replace(with: snapshot.items)
                return snapshot
            }
        )

        githubRuntimeModel.onActivitySourceChanged = { [weak self] in
            self?.menuBarController?.refreshActivityNow()
        }

        githubRuntimeModel.onDeliveryRecovery = { event in
            Task {
                await deliveryRecoveryNotifier.deliver(event)
            }
        }

        Task {
            await deliveryRecoveryNotifier.prepareAuthorization()
        }

        Task { @MainActor [weak self] in
            await self?.githubRuntimeModel.load()
        }
    }
}
