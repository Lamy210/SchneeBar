import SwiftUI
import SchneeBarCompanionCore

/// Isolated settings surface for development integration. This view does not
/// own a renderer, runtime gate, status item, event listener or CPU sampler.
@MainActor
public struct CompanionHostSettingsView: View {
    @Bindable private var model: CompanionHostSettingsModel

    public init(model: CompanionHostSettingsModel) {
        self.model = model
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
