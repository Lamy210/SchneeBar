import AppKit
import Combine
import SchneeBarCompanionCore
import SchneeBarCompanionAssets
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
    @State private var recoveryConfirmation: CompanionPreviewModel.RecoveryConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Companion Preview", systemImage: "snowflake")
                .font(.title2.weight(.semibold))
            Text("Developer-only preview. Quit regular SchneeBar and SchneeRunner before starting. Single images are session-only. Packs and selection use a separate preview library. No Runner settings are imported.")
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
                Toggle("Listen to local Runner events", isOn: $model.listenToLocalEvents)
                    .disabled(!model.started || !model.showCharacter)
                Text("Local events are untrusted and affect only the preview character.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                LabeledContent("Image", value: model.imageSourceTitle)
                HStack {
                    Button("Choose image…") { model.chooseImage() }
                    Button("Session default") { model.restoreBuiltInImage() }
                }
                .disabled(model.imageSelectionSession == nil || model.libraryBusy)
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
                packLibrary
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
                .disabled(model.libraryBusy)
            }
            if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
        .alert(item: $recoveryConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.action.title),
                message: Text(confirmation.action.detail),
                primaryButton: .destructive(Text(confirmation.action.title)) {
                    model.confirmRecovery(confirmation)
                },
                secondaryButton: .cancel()
            )
        }
        .onDisappear {
            recoveryConfirmation = nil
            model.stop()
        }
        .onChange(of: model.imageSelectionSession) { _, _ in
            recoveryConfirmation = nil
        }
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

    @ViewBuilder private var packLibrary: some View {
        if model.libraryAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Character library").font(.headline)
                if let library = model.libraryInventory {
                    Text("\(library.entries.count + library.trashedIDs.count) / \(CompanionOwnedPackStore.maximumInstalledPacks) slots (including trash)")
                        .font(.caption).foregroundStyle(.secondary)
                    if library.abandonedStageCount > 0 || library.pendingSelectionRecovery || library.unknownEntryCount > 0 {
                        Label("Recovery needed before importing.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                    if library.entries.isEmpty {
                        Text("No installed packs").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(library.entries) { entry in
                                    HStack {
                                        if let image = model.libraryThumbnails[entry.id] {
                                            Image(decorative: image, scale: 1)
                                                .resizable().interpolation(.high)
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 36, height: 36)
                                                .accessibilityHidden(true)
                                        } else {
                                            Button {
                                                model.loadThumbnail(entry.id)
                                            } label: {
                                                Image(systemName: "photo")
                                                    .frame(width: 30, height: 30)
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(entry.name == nil)
                                            .accessibilityLabel("Load thumbnail for \(entry.name ?? "unavailable pack")")
                                        }
                                        VStack(alignment: .leading) {
                                            Text(entry.name ?? "Unavailable pack").lineLimit(1)
                                            if let count = entry.clipCount {
                                                Text("\(count) clips").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Button(model.imageSource == .installedPack(entry.id) ? "Selected" : "Select") {
                                            model.selectPack(entry.id)
                                        }
                                        .disabled(entry.name == nil || model.imageSource == .installedPack(entry.id))
                                        Button {
                                            recoveryConfirmation = model.recoveryConfirmation(.trash(entry.id))
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .accessibilityLabel("Move \(entry.name ?? "unavailable pack") to trash")
                                    }
                                }
                            }
                        }.frame(maxHeight: 120)
                    }
                    Button("Import pack…") { model.choosePack() }.disabled(!library.canInstall)
                    if !library.trashedIDs.isEmpty || library.abandonedStageCount > 0 ||
                        library.pendingSelectionRecovery || library.unknownEntryCount > 0 {
                        DisclosureGroup("Trash and recovery") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(library.trashedIDs, id: \.self) { id in
                                        VStack(alignment: .leading) {
                                            Text("Trash: " + id.uuidString).font(.caption).textSelection(.enabled)
                                            HStack {
                                                Button("Restore") {
                                                    recoveryConfirmation = model.recoveryConfirmation(.restore(id))
                                                }
                                                Button("Delete permanently", role: .destructive) {
                                                    recoveryConfirmation = model.recoveryConfirmation(.purge(id))
                                                }
                                            }
                                        }
                                    }
                                    ForEach(library.abandonedStageIDs, id: \.self) { id in
                                        VStack(alignment: .leading) {
                                            Text("Incomplete import: " + id.uuidString).font(.caption).textSelection(.enabled)
                                            Button("Discard incomplete import", role: .destructive) {
                                                recoveryConfirmation = model.recoveryConfirmation(.discardStage(id))
                                            }
                                        }
                                    }
                                    if library.pendingSelectionRecovery {
                                        Button("Discard uncommitted selection", role: .destructive) {
                                            recoveryConfirmation = model.recoveryConfirmation(.discardPendingSelection)
                                        }
                                    }
                                    if library.unknownEntryCount > 0 {
                                        Text("\(library.unknownEntryCount) unknown entries. No automatic removal; inspect the dedicated preview library before importing.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.frame(maxHeight: 150)
                        }
                    }
                }
                HStack {
                    Button("Refresh") { model.refreshLibrary() }
                    Button("Restore saved") { model.restoreSavedChoice() }
                    Button("Use built-in") { model.selectLibraryDefault() }
                }
            }.disabled(!model.canUseLibrary)
            if model.libraryBusy {
                ProgressView("Library operation…").controlSize(.small)
            }
            if !model.libraryMessage.isEmpty {
                Text(model.libraryMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
