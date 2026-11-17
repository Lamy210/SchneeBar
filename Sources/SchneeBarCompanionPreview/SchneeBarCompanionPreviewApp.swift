import AppKit
import Combine
import SchneeBarCompanionCore
import SchneeBarDesignSystem
import SwiftUI

@main
struct SchneeBarCompanionPreviewApp: App {
    var body: some Scene {
        Window("Companion Preview", id: "companion-preview") {
            CompanionPreviewView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private struct CompanionPreviewView: View {
    @StateObject private var model = CompanionPreviewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Companion Preview", systemImage: "snowflake")
                .font(.title2.weight(.semibold))
            Text("Developer-only preview. Quit regular SchneeBar and SchneeRunner before starting. Selected images are used in memory only. No settings are imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show character", isOn: $model.showCharacter)
                Toggle("Show host CPU", isOn: $model.showCPU)
                Toggle("Automatic CPU speed", isOn: $model.automatic)
                    .disabled(!model.showCharacter)
                Picker("Playback speed", selection: $model.manualRate) {
                    ForEach(CompanionPlaybackRate.allCases, id: \.rawValue) { rate in
                        Text(rate.factor.formatted(.number.precision(.fractionLength(0...2))) + "×")
                            .tag(rate)
                    }
                }
                .disabled(model.automatic || !model.showCharacter)
                Toggle("Freeze animation", isOn: $model.freeze)
                    .disabled(!model.showCharacter)
                Divider()
                LabeledContent("Image", value: model.imageSource == .builtIn ? "Built-in" : "Selected file")
                HStack {
                    Button("Choose image…") { model.chooseImage() }
                    Button("Restore default") { model.restoreBuiltInImage() }
                }
                .disabled(model.imageSelectionSession == nil)
                if model.imageImportPending {
                    ProgressView("Loading image…").controlSize(.small)
                }
                if !model.imageMessage.isEmpty {
                    Text(model.imageMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                LabeledContent("State", value: String(describing: model.state))
                LabeledContent("Effective speed", value: model.effectiveRate.formatted()
                    + "×")
                if !model.cpuText.isEmpty { Text(model.cpuText).font(.caption) }
            }
            .padding(16)
            .schneeSurface()

            HStack {
                Button(model.started ? "Stop preview" : "Start preview") {
                    if model.started { model.stop() } else { model.start() }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Quit") {
                    model.stop()
                    NSApp.terminate(nil)
                }
            }
            if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDisappear { model.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.willSleepNotification
        )) { _ in model.setSleeping(true) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didWakeNotification
        )) { _ in model.setSleeping(false) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )) { _ in model.accessibilityChanged() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification
        )) { _ in model.appLaunched() }
    }
}
