import Foundation
import SwiftUI
import SchneeBarCompanionCore

/// Isolated settings surface for development integration. This view does not
/// own a renderer, runtime gate, status item, event listener or CPU sampler.
@MainActor
public struct CompanionHostSettingsView: View {
    @Bindable private var model: CompanionHostSettingsModel
    private let assets: CompanionHostAssetSettingsModel?

    public init(model: CompanionHostSettingsModel) {
        self.model = model
        self.assets = nil
    }

    public init(owner: CompanionHostComposition) {
        self.model = owner.settings
        self.assets = owner.assetSettings
    }

    public var body: some View {
        Form {
            Section("Companion preferences") {
                Text("Saved preferences only. Companion runtime approval is separate.")
                    .foregroundStyle(.secondary)
                Toggle("Enable companion", isOn: $model.draft.enabled)
                Toggle("Show menu character", isOn: $model.draft.showMenuCharacter)
                Picker("Presentation", selection: $model.draft.preset) {
                    Text("Minimal").tag(CompanionPresentationPreset.minimal)
                    Text("Dashboard").tag(CompanionPresentationPreset.dashboard)
                    Text("Companion").tag(CompanionPresentationPreset.companion)
                }
                Picker("Animation speed", selection: $model.draft.speed) {
                    Text("Automatic").tag(CompanionHostPreferences.Speed.automatic)
                    Text("0.5×").tag(CompanionHostPreferences.Speed.half)
                    Text("2/3×").tag(CompanionHostPreferences.Speed.twoThirds)
                    Text("1×").tag(CompanionHostPreferences.Speed.normal)
                    Text("1.5×").tag(CompanionHostPreferences.Speed.oneAndHalf)
                    Text("2×").tag(CompanionHostPreferences.Speed.double)
                }
                Toggle("Freeze animation", isOn: $model.draft.freeze)
                Toggle("Allow local activity events", isOn: $model.draft.allowLocalEvents)
            }
            .disabled(model.requiresRecovery)

            if let assets {
                CompanionHostAssetSettingsSection(model: assets)
            }

            if model.requiresRecovery {
                Section("Recovery") {
                    switch model.baseline {
                    case .unsupportedVersion(let version):
                        Text("Unsupported settings version: \(version). Existing settings are preserved.")
                    default:
                        Text("Settings could not be read. Existing settings are preserved.")
                    }
                    Button("Reset companion settings…", role: .destructive) {
                        model.requestReset()
                    }
                }
            }

            Section {
                HStack {
                    Button("Reload") { model.reload() }
                    Spacer()
                    Button("Discard edits") { model.discardEdits() }
                        .disabled(!model.hasChanges)
                    Button("Save") { model.save() }
                        .disabled(!model.canSave)
                }
                noticeView
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset companion settings?",
            isPresented: Binding(get: { model.resetConfirmation != nil },
                set: { if !$0 { model.cancelReset() } }),
            titleVisibility: .visible,
            presenting: model.resetConfirmation
        ) { token in
            Button("Reset", role: .destructive) { model.confirmReset(token) }
            Button("Cancel", role: .cancel) { model.cancelReset() }
        } message: { _ in
            Text("Only the saved companion preference record will be removed. This does not delete character packs or other settings.")
        }
    }

    @ViewBuilder
    private var noticeView: some View {
        switch model.notice {
        case .none: EmptyView()
        case .saved: Text("Preferences saved.")
        case .reloaded: Text("Preferences reloaded.")
        case .changedExternally: Text("Settings changed elsewhere. Review the latest values before retrying.")
        case .saveFailed: Text("The operation could not be verified. Review the current settings.")
        case .reset: Text("Saved companion preferences reset.")
        }
    }
}


/// Developer-only owned-library metadata picker. A manifest name does not
/// prove that its images can be decoded. Display/save still validate by UUID.
@MainActor
private struct CompanionHostAssetSettingsSection: View {
    @Bindable var model: CompanionHostAssetSettingsModel

    var body: some View {
        Section("Installed character packs") {
            Text("Choose an installed pack. Display does not save your choice. Save and clear change only the owned selection record.")
                .foregroundStyle(.secondary)
            Button("Refresh installed packs") { model.refreshInventory() }
                .disabled(!model.canOperate)
            Picker("Installed pack", selection: Binding<UUID?>(
                get: { model.listedID }, set: { model.chooseListedPack($0) }
            )) {
                Text("Choose a pack").tag(nil as UUID?)
                ForEach(model.entries.filter { $0.name != nil }) { entry in
                    Text((entry.name ?? "Unavailable") + " · " + String(entry.id.uuidString.prefix(8)))
                        .tag(Optional(entry.id))
                }
            }
            .disabled(!model.canOperate || !model.entries.contains(where: { $0.name != nil }))
            if model.inventoryStatus == .failed {
                Text("Unable to read the installed pack list. Refresh to retry.")
                    .foregroundStyle(.secondary)
            }
            if model.inventoryStatus == .loaded && model.entries.isEmpty {
                Text("No installed packs.").foregroundStyle(.secondary)
            }
            if model.entries.contains(where: { $0.name == nil }) {
                Text("Some packs have unavailable metadata and cannot be chosen from the list.")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced UUID entry (development)") {
                TextField("Installed pack UUID", text: $model.packIDText)
                    .disabled(!model.canOperate)
            }
            HStack {
                Button("Display") { model.displayCandidate() }
                Button("Save selection") { model.saveCandidate() }
            }
            .disabled(!model.canSelect)
            HStack {
                Button("Restore saved") { model.restoreSaved() }
                Button("Clear saved selection…", role: .destructive) { model.requestClear() }
            }
            .disabled(!model.canOperate)
            if model.isBusy {
                ProgressView("Asset operation still running…").controlSize(.small)
            }
            if !model.canOperate && !model.isBusy {
                Text("Asset operations require an approved, active or awaiting-catalogue host.")
                    .foregroundStyle(.secondary)
            }
            statusView
            if model.notice == .rejected {
                Text("Operation not accepted. Check the pack UUID and current host state.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Clear saved character selection?",
            isPresented: Binding(get: { model.clearConfirmation != nil },
                set: { if !$0 { model.cancelClear() } }),
            titleVisibility: .visible, presenting: model.clearConfirmation
        ) { token in
            Button("Clear saved selection", role: .destructive) { model.confirmClear(token) }
            Button("Cancel", role: .cancel) { model.cancelClear() }
        } message: { _ in
            Text("The selection record will be removed. Installed packs are not deleted.")
        }
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle: EmptyView()
        case .loading: Text("Loading installed pack…")
        case .loaded: Text("Installed pack displayed.")
        case .failed: Text("Unable to load pack. Original image restored.")
        case .restoring: Text("Reading saved selection…")
        case .noSavedSelection: Text("No saved selection.")
        case .savedAssetUnavailable: Text("Saved pack unavailable. Selection record retained.")
        case .restoreFailed: Text("Unable to read saved selection.")
        case .savingSelection: Text("Saving selection…")
        case .clearingSelection: Text("Clearing selection…")
        case .selectionSaved: Text("Selection saved.")
        case .selectionCleared: Text("Selection cleared.")
        case .selectionCommitFailed: Text("Selection operation failed or could not be verified. Restore saved to check the persisted choice.")
        }
    }
}
