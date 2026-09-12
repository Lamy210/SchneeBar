import AppKit
import Foundation
import SchneeBarActivityFeature
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
    outputDirectory: URL
) throws {
    let nsAppearance = NSAppearance(named: appearance.appKitAppearance)
    NSApplication.shared.appearance = nsAppearance

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.appearance = nsAppearance
    hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 620)

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
