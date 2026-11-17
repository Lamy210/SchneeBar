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
