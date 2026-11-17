import Darwin
import Foundation
@testable import SchneeBarCompanionAssets
import Testing

private let ownedGIF = "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="
private let ownedManifest = #"{"formatVersion":1,"name":"Original","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"original.gif"}]}"#
private enum StoreFault: Error { case injected }

private func withStore(_ body: (URL, URL) throws -> Void) throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = tmp.appendingPathComponent("source.schneerunner", isDirectory: true)
    let target = tmp.appendingPathComponent("owned", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try #require(Data(base64Encoded: ownedGIF)).write(to: source.appendingPathComponent("original.gif"))
    try Data(ownedManifest.utf8).write(to: source.appendingPathComponent("character.json"))
    try body(source, target)
}

@Test func ownedPackPublishesCanonicalCopyWithoutChangingSource() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        let name = installed.id.uuidString.lowercased() + ".schneerunner"
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == [name])
        let package = target.appendingPathComponent(name, isDirectory: true)
        #expect(try Data(contentsOf: source.appendingPathComponent("character.json")) == Data(ownedManifest.utf8))
        #expect(try Data(contentsOf: package.appendingPathComponent("run.gif")) == Data(base64Encoded: ownedGIF))
        let reloaded = try CompanionAnimatedPackLoader.load(package)
        #expect(reloaded.asset(for: .run).clip.durations == installed.catalogue.asset(for: .run).clip.durations)
        #expect(reloaded.asset(for: .run).frames.count == 2)
    }
}

@Test func ownedPackRollsBackInjectedPrecommitFailureAndKeepsExistingPack() throws {
    try withStore { source, target in
        let first = try CompanionOwnedPackStore.install(from: source, into: target)
        let name = first.id.uuidString.lowercased() + ".schneerunner"
        #expect(throws: StoreFault.injected) {
            try CompanionOwnedPackStore.install(from: source, into: target) { throw StoreFault.injected }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == [name])
        #expect(try Data(contentsOf: source.appendingPathComponent("character.json")) == Data(ownedManifest.utf8))
    }
}

@Test func ownedPackRejectsInvalidSourceAndUnsafeRoot() throws {
    try withStore { source, target in
        let link = target.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: CompanionOwnedPackError.unsafeRoot) {
            try CompanionOwnedPackStore.install(from: source, into: link)
        }
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("original.gif"))
        #expect(throws: (any Error).self) {
            try CompanionOwnedPackStore.install(from: source, into: target)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}

@Test func ownedInventoryListsMetadataAndReloadsByID() throws {
    try withStore { source, target in
        let install = try CompanionOwnedPackStore.install(from: source, into: target)
        let inventory = try CompanionOwnedPackStore.inventory(in: target)
        #expect(inventory.entries.count == 1)
        #expect(inventory.entries.first?.id == install.id)
        #expect(inventory.entries.first?.name == "Original")
        #expect(inventory.entries.first?.clipCount == 1)
        #expect(inventory.canInstall)
        let loaded = try CompanionOwnedPackStore.load(id: install.id, from: target)
        #expect(loaded.asset(for: .run).clip.durations == install.catalogue.asset(for: .run).clip.durations)
        #expect(throws: CompanionOwnedPackError.missingPack) {
            try CompanionOwnedPackStore.load(id: UUID(), from: target)
        }
    }
}

@Test func ownedInventoryReportsCorruptManifestAndRejectsSymlinkSelection() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        let original = target.appendingPathComponent(CompanionOwnedPackStore.packName(installed.id))
        try Data([1]).write(to: original.appendingPathComponent("character.json"))
        let alias = UUID()
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent(CompanionOwnedPackStore.packName(alias)),
            withDestinationURL: source)
        let invalid = try CompanionOwnedPackStore.inventory(in: target)
        #expect(invalid.entries.count == 2)
        #expect(invalid.entries.allSatisfy { $0.name == nil && $0.clipCount == nil })
        #expect(throws: CompanionOwnedPackError.missingPack) {
            try CompanionOwnedPackStore.load(id: alias, from: target)
        }
        #expect(throws: (any Error).self) {
            try CompanionOwnedPackStore.load(id: installed.id, from: target)
        }
    }
}

@Test func ownedInstallQuotaAndStaleStageFailClosedWithoutDeletingFiles() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        #expect(throws: CompanionOwnedPackError.packLimit) {
            try CompanionOwnedPackStore.install(from: source, into: target, maximumPacks: 1) {}
        }
        let stage = target.appendingPathComponent(".stage-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let other = target.appendingPathComponent("unrecognized")
        try Data([9]).write(to: other)
        let inventory = try CompanionOwnedPackStore.inventory(in: target)
        #expect(inventory.abandonedStageCount == 1)
        #expect(inventory.unknownEntryCount == 1)
        #expect(!inventory.canInstall)
        #expect(throws: CompanionOwnedPackError.recoveryRequired) {
            try CompanionOwnedPackStore.install(from: source, into: target)
        }
        #expect(FileManager.default.fileExists(atPath: stage.path))
        #expect(try Data(contentsOf: other) == Data([9]))
        #expect(inventory.entries.first?.id == installed.id)
    }
}

@Test func ownedInventoryScanLimitAndLockContentionFailClosed() throws {
    try withStore { source, target in
        let fd = try CompanionOwnedPackStore.openRoot(target)
        defer { _ = Darwin.close(fd) }
        try CompanionOwnedPackStore.lockRoot(fd, exclusive: true)
        #expect(throws: CompanionOwnedPackError.busy) {
            try CompanionOwnedPackStore.inventory(in: target)
        }
        #expect(throws: CompanionOwnedPackError.busy) {
            try CompanionOwnedPackStore.install(from: source, into: target)
        }
        try #require(flock(fd, LOCK_UN) == 0)
        for i in 0..<129 {
            try Data([0]).write(to: target.appendingPathComponent(".unknown-\(i)"))
        }
        #expect(throws: CompanionOwnedPackError.inventoryLimit) {
            try CompanionOwnedPackStore.inventory(in: target)
        }
    }
}

@Test func ownedTrashRestoreAndPurgePreserveSourceAndSlotAccounting() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        try CompanionOwnedPackStore.trash(id: installed.id, in: target)
        let trashed = try CompanionOwnedPackStore.inventory(in: target)
        #expect(trashed.entries.isEmpty)
        #expect(trashed.trashedIDs == [installed.id])
        #expect(throws: CompanionOwnedPackError.missingPack) {
            try CompanionOwnedPackStore.load(id: installed.id, from: target)
        }
        #expect(throws: CompanionOwnedPackError.packLimit) {
            try CompanionOwnedPackStore.install(from: source, into: target, maximumPacks: 1) {}
        }
        try CompanionOwnedPackStore.restore(id: installed.id, in: target)
        let reloaded = try CompanionOwnedPackStore.load(id: installed.id, from: target)
        #expect(reloaded.asset(for: .run).clip.durations == installed.catalogue.asset(for: .run).clip.durations)
        try CompanionOwnedPackStore.trash(id: installed.id, in: target)
        try CompanionOwnedPackStore.purgeTrash(id: installed.id, in: target)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try Data(contentsOf: source.appendingPathComponent("character.json")) == Data(ownedManifest.utf8))
        _ = try CompanionOwnedPackStore.install(from: source, into: target, maximumPacks: 1) {}
    }
}

@Test func ownedRestoreNeverOverwritesAndTrashRejectsSymlinks() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        try CompanionOwnedPackStore.trash(id: installed.id, in: target)
        let occupied = target.appendingPathComponent(CompanionOwnedPackStore.packName(installed.id))
        try Data([8]).write(to: occupied)
        #expect(throws: CompanionOwnedPackError.moveFailed) {
            try CompanionOwnedPackStore.restore(id: installed.id, in: target)
        }
        #expect(try Data(contentsOf: occupied) == Data([8]))
        let alias = UUID()
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent(CompanionOwnedPackStore.packName(alias)),
                                                  withDestinationURL: source)
        #expect(throws: CompanionOwnedPackError.missingPack) {
            try CompanionOwnedPackStore.trash(id: alias, in: target)
        }
        #expect(try CompanionOwnedPackStore.inventory(in: target).trashedIDs == [installed.id])
    }
}

@Test func ownedRecoveryRefusesUnknownAndLinkedContentBeforeDeletingAnything() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        try CompanionOwnedPackStore.trash(id: installed.id, in: target)
        let trash = target.appendingPathComponent(CompanionOwnedPackStore.trashName(installed.id))
        let unknown = trash.appendingPathComponent("unrelated.txt")
        let existing = trash.appendingPathComponent("run.gif")
        let bytes = try Data(contentsOf: existing)
        try Data([1]).write(to: unknown)
        #expect(throws: CompanionOwnedPackError.unsafeCleanup) {
            try CompanionOwnedPackStore.purgeTrash(id: installed.id, in: target)
        }
        #expect(try Data(contentsOf: existing) == bytes)
        try FileManager.default.removeItem(at: unknown)
        let link = trash.appendingPathComponent("walk.gif")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent("original.gif"))
        #expect(throws: CompanionOwnedPackError.unsafeCleanup) {
            try CompanionOwnedPackStore.purgeTrash(id: installed.id, in: target)
        }
        #expect(try Data(contentsOf: existing) == bytes)
        #expect(try Data(contentsOf: source.appendingPathComponent("original.gif")) == bytes)
    }
}

@Test func ownedRecoveryDiscardsOnlyExplicitCanonicalAbandonedStage() throws {
    try withStore { source, target in
        let installed = try CompanionOwnedPackStore.install(from: source, into: target)
        let id = UUID()
        let stage = target.appendingPathComponent(CompanionOwnedPackStore.stageName(id))
        let sequence = stage.appendingPathComponent("walk")
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fm.createDirectory(at: sequence, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let frame = sequence.appendingPathComponent("frame-000.png")
        try #require(fm.createFile(atPath: frame.path, contents: Data(),
                                  attributes: [.posixPermissions: NSNumber(value: 0o600)]))
        #expect(try CompanionOwnedPackStore.inventory(in: target).abandonedStageIDs == [id])
        try CompanionOwnedPackStore.discardAbandonedStage(id: id, in: target)
        #expect(!fm.fileExists(atPath: stage.path))
        let inventory = try CompanionOwnedPackStore.inventory(in: target)
        #expect(inventory.entries.first?.id == installed.id)
        #expect(inventory.abandonedStageCount == 0)
        #expect(inventory.canInstall)
    }
}

@Test func ownedSelectionPersistsOnlyValidatedChoiceAndRestoresBuiltIn() throws {
    try withStore { source, target in
        let first = try CompanionOwnedPackStore.install(from: source, into: target)
        let initial = try CompanionOwnedPackStore.restoreSelection(in: target)
        guard case .builtIn = initial else { Issue.record("expected built-in"); return }
        let selected = try CompanionOwnedPackStore.select(id: first.id, in: target)
        guard case let .installed(id, catalogue) = selected else { Issue.record("expected selected"); return }
        #expect(id == first.id)
        #expect(catalogue.asset(for: .run).frames.count == 2)
        #expect(try CompanionOwnedPackStore.inventory(in: target).canInstall)
        #expect(throws: CompanionOwnedPackError.missingPack) {
            try CompanionOwnedPackStore.select(id: UUID(), in: target)
        }
        let restored = try CompanionOwnedPackStore.restoreSelection(in: target)
        guard case let .installed(restoredID, _) = restored else { Issue.record("expected restored"); return }
        #expect(restoredID == first.id)
        try CompanionOwnedPackStore.selectBuiltIn(in: target)
        guard case .builtIn = try CompanionOwnedPackStore.restoreSelection(in: target) else {
            Issue.record("expected built-in after reset"); return
        }
    }
}

@Test func ownedSelectionTrashAndRestoreDoNotResurrectChoice() throws {
    try withStore { source, target in
        let first = try CompanionOwnedPackStore.install(from: source, into: target)
        _ = try CompanionOwnedPackStore.select(id: first.id, in: target)
        try CompanionOwnedPackStore.trash(id: first.id, in: target)
        try CompanionOwnedPackStore.restore(id: first.id, in: target)
        guard case .builtIn = try CompanionOwnedPackStore.restoreSelection(in: target) else {
            Issue.record("trash must clear persistent selection"); return
        }
        _ = try CompanionOwnedPackStore.select(id: first.id, in: target)
        let leaf = target.appendingPathComponent(CompanionOwnedPackStore.packName(first.id))
            .appendingPathComponent("run.gif")
        try Data([1]).write(to: leaf)
        guard case let .unavailable(id) = try CompanionOwnedPackStore.restoreSelection(in: target) else {
            Issue.record("expected unavailable choice"); return
        }
        #expect(id == first.id)
        try #require(Data(base64Encoded: ownedGIF)).write(to: leaf)
        guard case .builtIn = try CompanionOwnedPackStore.restoreSelection(in: target) else {
            Issue.record("damaged selection must not resurrect"); return
        }
    }
}

@Test func ownedSelectionWriteFailureKeepsPreviousChoiceAndPendingRecoveryNeverReplays() throws {
    try withStore { source, target in
        let first = try CompanionOwnedPackStore.install(from: source, into: target)
        let second = try CompanionOwnedPackStore.install(from: source, into: target)
        _ = try CompanionOwnedPackStore.select(id: first.id, in: target)
        #expect(throws: StoreFault.injected) {
            try CompanionOwnedPackStore.select(id: second.id, in: target) { throw StoreFault.injected }
        }
        let pending = target.appendingPathComponent(CompanionOwnedPackStore.selectionStageName)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        try #require(FileManager.default.createFile(atPath: pending.path,
            contents: Data("v1\n\(second.id.uuidString.lowercased())\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]))
        #expect(!((try CompanionOwnedPackStore.inventory(in: target)).canInstall))
        #expect(throws: CompanionOwnedPackError.recoveryRequired) {
            try CompanionOwnedPackStore.select(id: second.id, in: target)
        }
        try CompanionOwnedPackStore.discardPendingSelection(in: target)
        guard case let .installed(id, _) = try CompanionOwnedPackStore.restoreSelection(in: target) else {
            Issue.record("expected previous choice"); return
        }
        #expect(id == first.id)
    }
}

@Test func ownedSelectionRejectsUnsafeRecordAndAllowsExplicitMalformedReset() throws {
    try withStore { source, target in
        let record = target.appendingPathComponent(CompanionOwnedPackStore.selectionName)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: source.appendingPathComponent("character.json"))
        #expect(throws: CompanionOwnedPackError.invalidSelection) {
            try CompanionOwnedPackStore.restoreSelection(in: target)
        }
        #expect(throws: CompanionOwnedPackError.invalidSelection) {
            try CompanionOwnedPackStore.selectBuiltIn(in: target)
        }
        #expect(try Data(contentsOf: source.appendingPathComponent("character.json")) == Data(ownedManifest.utf8))
        try FileManager.default.removeItem(at: record)
        try #require(FileManager.default.createFile(atPath: record.path, contents: Data([1]),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]))
        #expect(throws: CompanionOwnedPackError.invalidSelection) {
            try CompanionOwnedPackStore.restoreSelection(in: target)
        }
        try CompanionOwnedPackStore.selectBuiltIn(in: target)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }
}

@Test func ownedPendingSelectionIsDistinctFromUnknownButStillBlocksImport() throws {
    try withStore { source, target in
        let pending = target.appendingPathComponent(CompanionOwnedPackStore.selectionStageName)
        try #require(FileManager.default.createFile(atPath: pending.path, contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]))
        let inventory = try CompanionOwnedPackStore.inventory(in: target)
        #expect(inventory.pendingSelectionRecovery)
        #expect(inventory.unknownEntryCount == 0)
        #expect(!inventory.canInstall)
        #expect(throws: CompanionOwnedPackError.recoveryRequired) {
            try CompanionOwnedPackStore.install(from: source, into: target)
        }
        try CompanionOwnedPackStore.discardPendingSelection(in: target)
        try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: source.appendingPathComponent("character.json"))
        let unsafe = try CompanionOwnedPackStore.inventory(in: target)
        #expect(!unsafe.pendingSelectionRecovery)
        #expect(unsafe.unknownEntryCount == 1)
        #expect(!unsafe.canInstall)
    }
}
