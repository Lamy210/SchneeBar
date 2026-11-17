import Foundation
import Observation
import SchneeBarCompanionCore

/// One settings editor per injected store. Edits are not active or persistent
/// until explicit Save; runtime approval is outside the editor entirely.
@MainActor
@Observable
public final class CompanionHostSettingsModel {
    public enum Notice: Equatable, Sendable {
        case none, saved, reloaded, changedExternally, saveFailed, reset
    }

    private var baselineSnapshot: CompanionHostPreferenceStore.Snapshot
    public var baseline: CompanionHostPreferenceStore.ReadResult { baselineSnapshot.result }
    public var draft: CompanionHostPreferences
    public private(set) var notice: Notice = .none
    public private(set) var resetConfirmation: UUID?
    private let store: CompanionHostPreferenceStore

    public init(store: CompanionHostPreferenceStore) {
        self.store = store
        let snapshot = store.snapshot()
        self.baselineSnapshot = snapshot
        self.draft = snapshot.result.preferences
    }

    public var requiresRecovery: Bool {
        switch baseline {
        case .invalid, .unsupportedVersion: true
        case .missing, .valid: false
        }
    }

    public var hasChanges: Bool { draft != baseline.preferences }
    public var canSave: Bool { !requiresRecovery && hasChanges }
    public var committedPreferences: CompanionHostPreferences { baseline.preferences }

    public func reload() {
        adopt(store.snapshot(), notice: .reloaded)
    }

    public func discardEdits() {
        draft = baseline.preferences
        resetConfirmation = nil
        notice = .none
    }

    public func save() {
        guard canSave else { return }
        let current = store.snapshot()
        guard current.matches(baselineSnapshot) else {
            adopt(current, notice: .changedExternally)
            return
        }
        do {
            try store.save(draft)
            // Read back the domain value, not a promise of durable disk flush.
            let readBack = store.snapshot()
            let expected = CompanionHostPreferenceStore.ReadResult.valid(draft)
            adopt(readBack, notice: readBack.result == expected ? .saved : .saveFailed)
        } catch {
            adopt(store.snapshot(), notice: .saveFailed)
        }
    }

    /// A destructive reset is only offered for unreadable settings.
    public func requestReset() {
        guard requiresRecovery else { return }
        resetConfirmation = UUID()
    }

    public func cancelReset() {
        resetConfirmation = nil
    }

    public func confirmReset(_ token: UUID) {
        guard requiresRecovery, resetConfirmation == token else { return }
        resetConfirmation = nil
        let current = store.snapshot()
        guard current.matches(baselineSnapshot) else {
            adopt(current, notice: .changedExternally)
            return
        }
        store.reset()
        let readBack = store.snapshot()
        adopt(readBack, notice: readBack.result == .missing ? .reset : .saveFailed)
    }

    private func adopt(_ snapshot: CompanionHostPreferenceStore.Snapshot, notice: Notice) {
        baselineSnapshot = snapshot
        draft = snapshot.result.preferences
        resetConfirmation = nil
        self.notice = notice
    }
}
