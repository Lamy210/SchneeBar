import Foundation
import Observation
import SchneeBarCompanionCore

/// An isolated editor for the host-owned library. Never writes on draft
/// changes and never polls the worker. The caller still owns release approval.
@MainActor
@Observable
public final class CompanionHostAssetSettingsModel {
    public enum ActionNotice: Equatable, Sendable { case none, rejected }
    public var packIDText = ""
    public private(set) var notice: ActionNotice = .none
    public private(set) var status: CompanionOwnedAssetAcquisition.Status = .idle
    public private(set) var isBusy = false
    public private(set) var availability: CompanionHostPolicy.Availability = .releaseBlocked
    public private(set) var clearConfirmation: UUID?
    private var assetSession: UUID?
    @ObservationIgnored private weak var owner: CompanionHostComposition?

    init(owner: CompanionHostComposition) {
        self.owner = owner
        sync()
    }

    public var canOperate: Bool { owner != nil && assetSession != nil && !isBusy }
    public var candidateID: UUID? {
        guard packIDText.utf8.count <= 64 else { return nil }
        return UUID(uuidString: packIDText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public var canSelect: Bool { canOperate && candidateID != nil }

    /// Owner invokes on lifecycle changes, request start, adoption and actual drain.
    /// A stale destructive confirmation must not survive any relevant change.
    func sync() {
        let nextSession = owner?.decision.assetSession
        let nextStatus = owner?.assetStatus ?? .idle
        let nextBusy = owner?.isAssetWorkerBusy ?? false
        let nextAvailability = owner?.decision.availability ?? .releaseBlocked
        if nextSession != assetSession || nextStatus != status ||
            nextBusy != isBusy || nextAvailability != availability {
            clearConfirmation = nil
            assetSession = nextSession
            status = nextStatus
            isBusy = nextBusy
            availability = nextAvailability
        }
    }

    public func displayCandidate() {
        sync()
        guard canSelect, let id = candidateID, let owner else { notice = .rejected; return }
        notice = owner.requestInstalledAsset(id) ? .none : .rejected
    }

    public func saveCandidate() {
        sync()
        guard canSelect, let id = candidateID, let owner else { notice = .rejected; return }
        notice = owner.saveInstalledAssetSelection(id) ? .none : .rejected
    }

    public func restoreSaved() {
        sync()
        guard canOperate, let owner else { notice = .rejected; return }
        notice = owner.restoreSavedAssetSelection() ? .none : .rejected
    }

    public func requestClear() {
        sync()
        guard canOperate else { notice = .rejected; return }
        clearConfirmation = UUID()
    }

    public func cancelClear() { clearConfirmation = nil }

    public func confirmClear(_ token: UUID) {
        sync()
        guard canOperate, clearConfirmation == token, let owner else { return }
        clearConfirmation = nil
        notice = owner.clearSavedAssetSelection() ? .none : .rejected
    }
}
