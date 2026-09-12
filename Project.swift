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
            sources: ["Sources/SchneeBarDesignSystem/**"],
            dependencies: [
                .target(name: "SchneeBarCore"),
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
                .target(name: "SchneeBarDesignSystem"),
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
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarDesignSystem"),
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
                .target(name: "SchneeBarCore"),
                .target(name: "SchneeBarDesignSystem"),
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
    ]
)
