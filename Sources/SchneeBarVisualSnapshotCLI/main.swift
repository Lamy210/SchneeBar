import AppKit
import Foundation
import SchneeBarCore
import SchneeBarDesignSystem
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
private func render(
    scenario: ActivityFixtureScenario,
    appearance: SnapshotAppearance,
    outputDirectory: URL
) throws {
    NSApplication.shared.appearance = NSAppearance(named: appearance.appKitAppearance)

    // Render against a deterministic opaque backdrop. This both exercises
    // macOS 26 glass/material compositing and keeps light/dark text readable
    // when the PNG is viewed in CI reports with arbitrary page backgrounds.
    let root = ZStack {
        appearance.background

        ActivityPopoverView(items: scenario.items)
            .padding(24)
    }
    .frame(width: 400)
    .environment(\.colorScheme, appearance.colorScheme)

    let hostingView = NSHostingView(rootView: root)
    hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 520)
    hostingView.layoutSubtreeIfNeeded()

    let fittingHeight = max(hostingView.fittingSize.height, 1)
    hostingView.frame.size.height = fittingHeight
    hostingView.layoutSubtreeIfNeeded()

    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        throw SnapshotError.cannotCreateBitmap
    }

    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SnapshotError.cannotEncodePNG
    }

    let filename = "\(scenario.rawValue)-\(appearance.rawValue).png"
    try png.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
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
                scenario: scenario,
                appearance: appearance,
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
