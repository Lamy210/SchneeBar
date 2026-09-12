import ProjectDescription

let deploymentTarget: DeploymentTargets = .macOS("15.0")

let project = Project(
    name: "SchneeBar",
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
        ]
    ),
    targets: [
        .target(
            name: "SchneeBarCore",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.core",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarCore/**"]
        ),
        .target(
            name: "SchneeBarDesignSystem",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.design-system",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarDesignSystem/**"]
        ),
        .target(
            name: "SchneeBarWidgetFeature",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.widget-feature",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarWidgetFeature/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarDesignSystem"),
            ]
        ),
        .target(
            name: "SchneeBarActivityFeature",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.activity-feature",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarActivityFeature/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarDesignSystem"),
            ]
        ),
        .target(
            name: "SchneeBarSystemProvider",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.system-provider",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarSystemProvider/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
            ]
        ),
        .target(
            name: "SchneeBarPreferences",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.preferences",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarPreferences/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
            ]
        ),
        .target(
            name: "SchneeBarGitHub",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.github",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarGitHub/**"]
        ),
        .target(
            name: "SchneeBarGitHubKeychain",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.github-keychain",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarGitHubKeychain/**"],
            dependencies: [
                .target(name: "SchneeBarGitHub"),
            ]
        ),
        .target(
            name: "SchneeBarGitHubProfiles",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.github-profiles",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarGitHubProfiles/**"],
            dependencies: [
                .target(name: "SchneeBarGitHub"),
            ]
        ),
        .target(
            name: "SchneeBarGitHubFeature",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.github-feature",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarGitHubFeature/**"],
            dependencies: [
                .target(name: "SchneeBarGitHub"),
            ]
        ),
        .target(
            name: "SchneeBarPreviewSupport",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "dev.lamy.schneebar.preview-support",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarPreviewSupport/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarGitHubFeature"),
            ]
        ),
        .target(
            name: "SchneeBar",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.lamy.schneebar",
            deploymentTargets: deploymentTarget,
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "SchneeBar",
                    "LSUIElement": true,
                ]
            ),
            sources: ["Sources/SchneeBarApp/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarWidgetFeature"),
                .target(name: "SchneeBarActivityFeature"),
                .target(name: "SchneeBarSystemProvider"),
                .target(name: "SchneeBarPreferences"),
                .target(name: "SchneeBarGitHub"),
                .target(name: "SchneeBarGitHubKeychain"),
                .target(name: "SchneeBarGitHubProfiles"),
                .target(name: "SchneeBarGitHubFeature"),
            ]
        ),
        .target(
            name: "SchneeBarVisualHarness",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.lamy.schneebar.visual-harness",
            deploymentTargets: deploymentTarget,
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "SchneeBar Visual Harness",
                ]
            ),
            sources: ["Sources/SchneeBarVisualHarness/**"],
            dependencies: [
                .target(name: "SchneeBarWidgetFeature"),
                .target(name: "SchneeBarActivityFeature"),
                .target(name: "SchneeBarGitHubFeature"),
                .target(name: "SchneeBarPreviewSupport"),
            ]
        ),
        .target(
            name: "SchneeBarVisualSnapshotCLI",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "dev.lamy.schneebar.visual-snapshot-cli",
            deploymentTargets: deploymentTarget,
            sources: ["Sources/SchneeBarVisualSnapshotCLI/**"],
            dependencies: [
                .target(name: "SchneeBarWidgetFeature"),
                .target(name: "SchneeBarActivityFeature"),
                .target(name: "SchneeBarGitHubFeature"),
                .target(name: "SchneeBarPreviewSupport"),
            ]
        ),
        .target(
            name: "SchneeBarCoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.core-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarCoreTests/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
            ]
        ),
        .target(
            name: "SchneeBarActivityFeatureTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.activity-feature-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarActivityFeatureTests/**"],
            dependencies: [
                .target(name: "SchneeBarActivityFeature"),
            ]
        ),
        .target(
            name: "SchneeBarSystemProviderTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.system-provider-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarSystemProviderTests/**"],
            dependencies: [
                .target(name: "SchneeBarSystemProvider"),
            ]
        ),
        .target(
            name: "SchneeBarPreferencesTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.preferences-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarPreferencesTests/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarPreferences"),
            ]
        ),
        .target(
            name: "SchneeBarGitHubTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.github-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarGitHubTests/**"],
            dependencies: [
                .target(name: "SchneeBarGitHub"),
            ]
        ),
        .target(
            name: "SchneeBarGitHubKeychainTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.github-keychain-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarGitHubKeychainTests/**"],
            dependencies: [
                .target(name: "SchneeBarGitHub"),
                .target(name: "SchneeBarGitHubKeychain"),
            ]
        ),
        .target(
            name: "SchneeBarGitHubProfilesTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.lamy.schneebar.github-profiles-tests",
            deploymentTargets: deploymentTarget,
            sources: ["Tests/SchneeBarGitHubProfilesTests/**"],
            dependencies: [
                .target(name: "SchneeBarGitHub"),
                .target(name: "SchneeBarGitHubProfiles"),
            ]
        ),
    ]
)
