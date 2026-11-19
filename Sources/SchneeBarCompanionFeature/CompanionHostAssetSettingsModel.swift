import AppKit
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
    public var packIDText = "" {
        didSet {
            if packIDText != oldValue { previewCandidate = nil }
        }
    }
    public private(set) var notice: ActionNotice = .none
    public private(set) var status: CompanionOwnedAssetAcquisition.Status = .idle
    public private(set) var isBusy = false
    public private(set) var availability: CompanionHostPolicy.Availability = .releaseBlocked
    public private(set) var clearConfirmation: UUID?
    public private(set) var entries: [CompanionOwnedPackStore.Entry] = []
    public private(set) var inventoryStatus: CompanionOwnedAssetAcquisition.InventoryStatus = .idle
    private var assetSession: UUID?
    private var importPanelSession: UUID?
    public private(set) var importStatus: CompanionOwnedAssetAcquisition.ImportStatus = .idle
    public private(set) var inventoryAllowsImport = false
    private var previewCandidate: UUID?
    private var previewStatus: CompanionOwnedAssetAcquisition.PreviewStatus = .idle
    private var thumbnail: CompanionPackThumbnail?
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
    public var canImport: Bool { canOperate && inventoryAllowsImport && importPanelSession == nil }
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

    public var candidatePreviewStatus: CompanionOwnedAssetAcquisition.PreviewStatus {
        guard let previewCandidate, candidateID == previewCandidate else { return .idle }
        return previewStatus
    }

    public var candidateThumbnail: CompanionPackThumbnail? {
        guard let previewCandidate, candidateID == previewCandidate,
              previewStatus == .loaded(previewCandidate) else { return nil }
        return thumbnail
    }

    public func previewSelectedPack() {
        sync()
        guard canSelect, let id = candidateID, let owner else { notice = .rejected; return }
        previewCandidate = id
        if owner.requestAssetPreview(id) { notice = .none }
        else { previewCandidate = nil; notice = .rejected }
    }

    /// Native chooser is explicit. Keep one panel token and fence the result
    /// against both the editor and the host session, including sleep/wake.
    public func choosePackToImport() {
        guard let token = beginImportChoice() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        let url = panel.runModal() == .OK ? panel.url : nil
        completeImportChoice(token, url: url)
    }

    func beginImportChoice() -> UUID? {
        sync()
        guard canImport else { notice = .rejected; return nil }
        let token = UUID()
        importPanelSession = token
        return token
    }

    func completeImportChoice(_ token: UUID, url: URL?) {
        sync()
        guard importPanelSession == token else { return }
        importPanelSession = nil
        guard let url else { return }
        guard canImport, let owner, let session = assetSession else { notice = .rejected; return }
        notice = owner.importAssetPack(from: url, session: session) ? .none : .rejected
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
        inventoryAllowsImport = owner?.assetInventory?.canInstall == true
        importStatus = owner?.assetImportStatus ?? .idle
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
        let nextPreview = owner?.assetPreviewStatus ?? .idle
        if nextPreview != previewStatus {
            previewStatus = nextPreview
            thumbnail = owner?.assetThumbnail
        }
        if nextSession != assetSession || nextPreview == .idle {
            previewCandidate = nil
        }
        let nextStatus = owner?.assetStatus ?? .idle
        let nextBusy = owner?.isAssetWorkerBusy ?? false
        let nextAvailability = owner?.decision.availability ?? .releaseBlocked
        if nextSession != assetSession || nextStatus != status ||
            nextBusy != isBusy || nextAvailability != availability {
            clearConfirmation = nil
            importPanelSession = nil
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
