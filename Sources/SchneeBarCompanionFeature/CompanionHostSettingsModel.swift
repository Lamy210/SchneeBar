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

    public private(set) var baseline: CompanionHostPreferenceStore.ReadResult
    public var draft: CompanionHostPreferences
    public private(set) var notice: Notice = .none
    public private(set) var resetConfirmation: UUID?
    private let store: CompanionHostPreferenceStore

    public init(store: CompanionHostPreferenceStore) {
        self.store = store
        let result = store.load()
        self.baseline = result
        self.draft = result.preferences
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
        adopt(store.load(), notice: .reloaded)
    }

    public func discardEdits() {
        draft = baseline.preferences
        resetConfirmation = nil
        notice = .none
    }

    public func save() {
        guard canSave else { return }
        let current = store.load()
        guard current == baseline else {
            adopt(current, notice: .changedExternally)
            return
        }
        do {
            try store.save(draft)
            // Read back the domain value, not a promise of durable disk flush.
            let readBack = store.load()
            let expected = CompanionHostPreferenceStore.ReadResult.valid(draft)
            adopt(readBack, notice: readBack == expected ? .saved : .saveFailed)
        } catch {
            adopt(store.load(), notice: .saveFailed)
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
        let current = store.load()
        guard current == baseline else {
            adopt(current, notice: .changedExternally)
            return
        }
        store.reset()
        let readBack = store.load()
        adopt(readBack, notice: readBack == .missing ? .reset : .saveFailed)
    }

    private func adopt(_ result: CompanionHostPreferenceStore.ReadResult, notice: Notice) {
        baseline = result
        draft = result.preferences
        resetConfirmation = nil
        self.notice = notice
    }
}
