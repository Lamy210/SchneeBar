import Foundation
import Observation
import SchneeBarCompanionAssets
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
    public private(set) var entries: [CompanionOwnedPackStore.Entry] = []
    public private(set) var inventoryStatus: CompanionOwnedAssetAcquisition.InventoryStatus = .idle
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
    public var listedID: UUID? {
        guard let id = candidateID, entries.contains(where: { $0.id == id && $0.name != nil }) else { return nil }
        return id
    }

    public func chooseListedPack(_ id: UUID?) {
        sync()
        guard canOperate else { return }
        guard let id else { packIDText = ""; return }
        guard entries.contains(where: { $0.id == id && $0.name != nil }) else { return }
        packIDText = id.uuidString
    }

    public func refreshInventory() {
        sync()
        guard canOperate, let owner else { notice = .rejected; return }
        notice = owner.refreshAssetInventory() ? .none : .rejected
    }

    /// Owner invokes on lifecycle changes, request start, adoption and actual drain.
    /// A stale destructive confirmation must not survive any relevant change.
    func sync() {
        let nextEntries = owner?.assetInventory?.entries ?? []
        let nextInventoryStatus = owner?.assetInventoryStatus ?? .idle
        if entries != nextEntries {
            // A previously selected listed ID must not silently remain the
            // candidate after its metadata snapshot was invalidated.
            if let id = listedID, !nextEntries.contains(where: { $0.id == id && $0.name != nil }) {
                packIDText = ""
            }
            entries = nextEntries
        }
        if inventoryStatus != nextInventoryStatus { inventoryStatus = nextInventoryStatus }
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
