import AppKit
import Foundation
import SchneeBarActivityFeature
import SchneeBarGitHubFeature
import SchneeBarPreviewSupport
import SchneeBarWidgetFeature
import SwiftUI

private enum SnapshotAppearance: String, CaseIterable {
    case light
    case dark

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    var background: LinearGradient {
        let colors: [Color]
        switch self {
        case .light:
            colors = [
                Color(red: 0.94, green: 0.96, blue: 1.00),
                Color(red: 0.82, green: 0.88, blue: 0.97),
            ]
        case .dark:
            colors = [
                Color(red: 0.08, green: 0.10, blue: 0.16),
                Color(red: 0.16, green: 0.20, blue: 0.30),
            ]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private enum GitHubOnboardingSnapshotScenario: String, CaseIterable {
    case configuration
    case waiting
    case failure

    var draft: GitHubConnectionDraft {
        switch self {
        case .configuration, .waiting:
            GitHubConnectionDraft(
                deploymentKind: .githubDotCom,
                displayName: "GitHub.com",
                serverURL: "https://github.com",
                clientID: "Iv1.public-client-id"
            )
        case .failure:
            GitHubConnectionDraft(
                deploymentKind: .enterpriseServer,
                displayName: "Internal GitHub",
                serverURL: "https://github.internal.example:8443",
                clientID: "Iv1.enterprise-client"
            )
        }
    }

    var phase: GitHubConnectionOnboardingPhase {
        switch self {
        case .configuration:
            return .configuration
        case .waiting:
            return .waitingForAuthorization(
                GitHubDeviceAuthorizationPresentation(
                    userCode: "ABCD-EFGH",
                    verificationURI: URL(string: "https://github.com/login/device")!,
                    expiresAt: Date(timeIntervalSince1970: 2_000)
                )
            )
        case .failure:
            return .failed(
                message: "Could not reach the GitHub Enterprise Server. Check VPN and server URL."
            )
        }
    }
}

private enum GitHubRecoverySnapshotScenario: String, CaseIterable {
    case deviceCode = "device-code"
    case wrongAccount = "wrong-account"
    case finalizing

    var phase: GitHubConnectionRecoveryPhase {
        switch self {
        case .deviceCode:
            return .waitingForAuthorization(GitHubConnectionRecoveryFixture.authorization)
        case .wrongAccount:
            return .failed(
                message: "GitHub authorized a different account. Sign in as @snow-user and try again."
            )
        case .finalizing:
            return .finalizing
        }
    }
}

private enum SnapshotError: Error {
    case missingOutputDirectory
    case cannotCreateBitmap
    case cannotEncodePNG
}

@MainActor
private func render<Content: View>(
    rootView: Content,
    appearance: SnapshotAppearance,
    filename: String,
    outputDirectory: URL,
    width: CGFloat = 400,
    initialHeight: CGFloat = 620
) throws {
    let nsAppearance = NSAppearance(named: appearance.appKitAppearance)
    NSApplication.shared.appearance = nsAppearance

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.appearance = nsAppearance
    hostingView.frame = NSRect(x: 0, y: 0, width: width, height: initialHeight)

    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = nsAppearance
    window.isOpaque = true
    window.backgroundColor = appearance == .dark ? .black : .white
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFrontRegardless()

    defer {
        window.orderOut(nil)
        window.close()
    }

    hostingView.layoutSubtreeIfNeeded()
    let fittingHeight = max(hostingView.fittingSize.height, 1)
    hostingView.frame.size.height = fittingHeight
    window.setContentSize(hostingView.frame.size)
    hostingView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    hostingView.displayIfNeeded()

    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        throw SnapshotError.cannotCreateBitmap
    }

    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SnapshotError.cannotEncodePNG
    }

    try png.write(
        to: outputDirectory.appendingPathComponent(filename),
        options: .atomic
    )
}

@MainActor
private func activityRoot(
    scenario: ActivityFixtureScenario,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        ActivityPopoverView(
            items: scenario.items,
            surfaceStyle: .deterministic
        )
        .padding(24)
    }
    .frame(width: 400)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func activityDetailRoot(
    scenario: ActivityDetailFixtureScenario,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        ActivityDetailView(
            item: scenario.item,
            detail: scenario.detail,
            isLoading: false,
            errorMessage: nil,
            onBack: {},
            onRetry: {},
            surfaceStyle: .deterministic
        )
        .padding(24)
    }
    .frame(width: 400)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func widgetRoot(
    scenario: WidgetFixtureScenario,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        WidgetOverviewView(
            snapshots: scenario.snapshots,
            surfaceStyle: .deterministic
        )
        .padding(24)
    }
    .frame(width: 400)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func widgetSettingsRoot(appearance: SnapshotAppearance) -> some View {
    ZStack {
        appearance.background

        Form {
            WidgetSettingsView(
                descriptors: WidgetSettingsFixture.descriptors,
                configuration: WidgetSettingsFixture.configured,
                onSetEnabled: { _, _ in },
                onSetRepresentation: { _, _ in },
                onMove: { _, _ in }
            )
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(24)
    }
    .frame(width: 620)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func githubConnectionsRoot(
    fixture: GitHubConnectionsFixture,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        Form {
            GitHubConnectionsView(
                connections: fixture.connections,
                onAdd: {},
                onRefresh: { _ in },
                onReauthenticate: { _ in },
                onManage: { _ in },
                onSetEnabled: { _, _ in }
            )
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding(24)
    }
    .frame(width: 680)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func githubOnboardingRoot(
    scenario: GitHubOnboardingSnapshotScenario,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        GitHubConnectionOnboardingView(
            draft: .constant(scenario.draft),
            phase: scenario.phase,
            onConnect: {},
            onOpenVerificationPage: { _ in },
            onCancel: {}
        )
        .padding(24)
    }
    .frame(width: 580)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func githubRecoveryRoot(
    scenario: GitHubRecoverySnapshotScenario,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        GitHubConnectionRecoveryView(
            context: GitHubConnectionRecoveryFixture.context,
            phase: scenario.phase,
            onRetry: {},
            onOpenVerificationPage: { _ in },
            onCancel: {}
        )
        .padding(24)
    }
    .frame(width: 580)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func githubManagementRoot(
    model: GitHubConnectionManagementModel,
    selectedRepositoryIDs: Set<Int64>,
    appearance: SnapshotAppearance
) -> some View {
    ZStack {
        appearance.background

        GitHubConnectionManagementView(
            model: model,
            selectionMode: .constant(.selected),
            selectedRepositoryIDs: .constant(selectedRepositoryIDs),
            onRefresh: {},
            onSave: {},
            onDisconnect: {},
            onCancel: {}
        )
        .padding(24)
    }
    .frame(width: 760)
    .environment(\.colorScheme, appearance.colorScheme)
}

@MainActor
private func run() throws {
    guard let outputIndex = CommandLine.arguments.firstIndex(of: "--output"),
          CommandLine.arguments.indices.contains(outputIndex + 1)
    else {
        throw SnapshotError.missingOutputDirectory
    }

    let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[outputIndex + 1], isDirectory: true)
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )

    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    for scenario in ActivityFixtureScenario.allCases {
        for appearance in SnapshotAppearance.allCases {
            try render(
                rootView: activityRoot(scenario: scenario, appearance: appearance),
                appearance: appearance,
                filename: "activity-\(scenario.rawValue)-\(appearance.rawValue).png",
                outputDirectory: outputDirectory
            )
        }
    }

    for appearance in SnapshotAppearance.allCases {
        try render(
            rootView: activityRoot(scenario: .mixedInbox, appearance: appearance),
            appearance: appearance,
            filename: "github-activity-mixed-inbox-\(appearance.rawValue).png",
            outputDirectory: outputDirectory
        )
    }

    try render(
        rootView: activityRoot(scenario: .reviewOnly, appearance: .light),
        appearance: .light,
        filename: "github-activity-review-only-light.png",
        outputDirectory: outputDirectory
    )

    for appearance in SnapshotAppearance.allCases {
        try render(
            rootView: activityDetailRoot(scenario: .failed, appearance: appearance),
            appearance: appearance,
            filename: "activity-detail-failed-\(appearance.rawValue).png",
            outputDirectory: outputDirectory
        )
    }

    try render(
        rootView: activityDetailRoot(scenario: .matrixSuccess, appearance: .light),
        appearance: .light,
        filename: "matrix-success-light.png",
        outputDirectory: outputDirectory
    )

    for appearance in SnapshotAppearance.allCases {
        try render(
            rootView: activityDetailRoot(scenario: .matrixFailure, appearance: appearance),
            appearance: appearance,
            filename: "matrix-failure-\(appearance.rawValue).png",
            outputDirectory: outputDirectory
        )
    }

    let deliveryScenarios: [ActivityDetailFixtureScenario] = [
        .deliveryExact,
        .deliveryEvidenceUnavailable,
        .deliveryTemporarilyUnavailable,
        .deliveryMatrixFailure,
    ]
    for scenario in deliveryScenarios {
        for appearance in SnapshotAppearance.allCases {
            try render(
                rootView: activityDetailRoot(scenario: scenario, appearance: appearance),
                appearance: appearance,
                filename: "activity-detail-\(scenario.rawValue)-\(appearance.rawValue).png",
                outputDirectory: outputDirectory
            )
        }
    }

    for scenario in WidgetFixtureScenario.allCases {
        for appearance in SnapshotAppearance.allCases {
            try render(
                rootView: widgetRoot(scenario: scenario, appearance: appearance),
                appearance: appearance,
                filename: "widgets-\(scenario.rawValue)-\(appearance.rawValue).png",
                outputDirectory: outputDirectory
            )
        }
    }

    for appearance in SnapshotAppearance.allCases {
        try render(
            rootView: widgetSettingsRoot(appearance: appearance),
            appearance: appearance,
            filename: "widget-settings-\(appearance.rawValue).png",
            outputDirectory: outputDirectory,
            width: 620,
            initialHeight: 760
        )
    }

    for fixture in GitHubConnectionsFixture.allCases {
        for appearance in SnapshotAppearance.allCases {
            try render(
                rootView: githubConnectionsRoot(fixture: fixture, appearance: appearance),
                appearance: appearance,
                filename: "github-connections-\(fixture.rawValue)-\(appearance.rawValue).png",
                outputDirectory: outputDirectory,
                width: 680,
                initialHeight: 820
            )
        }
    }

    for scenario in GitHubOnboardingSnapshotScenario.allCases {
        for appearance in SnapshotAppearance.allCases {
            try render(
                rootView: githubOnboardingRoot(scenario: scenario, appearance: appearance),
                appearance: appearance,
                filename: "github-onboarding-\(scenario.rawValue)-\(appearance.rawValue).png",
                outputDirectory: outputDirectory,
                width: 580,
                initialHeight: 720
            )
        }
    }

    for scenario in GitHubRecoverySnapshotScenario.allCases {
        for appearance in SnapshotAppearance.allCases {
            try render(
                rootView: githubRecoveryRoot(scenario: scenario, appearance: appearance),
                appearance: appearance,
                filename: "github-recovery-\(scenario.rawValue)-\(appearance.rawValue).png",
                outputDirectory: outputDirectory,
                width: 580,
                initialHeight: 720
            )
        }
    }

    for appearance in SnapshotAppearance.allCases {
        try render(
            rootView: githubManagementRoot(
                model: GitHubConnectionManagementFixture.model,
                selectedRepositoryIDs: GitHubConnectionManagementFixture.selectedRepositoryIDs,
                appearance: appearance
            ),
            appearance: appearance,
            filename: "github-management-selected-\(appearance.rawValue).png",
            outputDirectory: outputDirectory,
            width: 760,
            initialHeight: 820
        )

        try render(
            rootView: githubManagementRoot(
                model: GitHubConnectionManagementFixture.mixedCapabilityModel,
                selectedRepositoryIDs: GitHubConnectionManagementFixture.mixedCapabilitySelectedRepositoryIDs,
                appearance: appearance
            ),
            appearance: appearance,
            filename: "github-capability-mixed-surfaces-\(appearance.rawValue).png",
            outputDirectory: outputDirectory,
            width: 760,
            initialHeight: 820
        )
    }
}

do {
    try MainActor.assumeIsolated {
        try run()
    }
} catch {
    let message = "SchneeBarVisualSnapshotCLI failed: \(error)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
