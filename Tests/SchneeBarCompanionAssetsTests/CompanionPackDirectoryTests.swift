import Darwin
import Foundation
import SchneeBarCompanionAssets
import Testing

private func withPack(_ body: (URL, URL) throws -> Void) throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent("example.schneerunner", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try body(root, parent)
}

@Test func packDescriptorReadsManifestAndNestedFileWithinByteBudget() throws {
    try withPack { root, _ in
        let data = Data([1, 2, 3])
        let clips = root.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: false)
        try data.write(to: clips.appendingPathComponent("run.gif"))
        try Data(#"{"formatVersion":1,"name":"Snow","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"clips/run.gif"}]}"#.utf8)
            .write(to: root.appendingPathComponent("character.json"))
        let directory = try CompanionPackDirectory(root)
        let manifest = try directory.manifest()
        let path = try #require(manifest.clips.first?.path)
        #expect(try directory.read(path, maximumBytes: 3) == data)
        #expect(throws: CompanionFileReadError.invalidSize) {
            try directory.read(path, maximumBytes: 2)
        }
    }
}

@Test func packDescriptorRejectsRootAncestorLeafSymlinksHardlinksAndFIFO() throws {
    try withPack { root, parent in
        let fm = FileManager.default
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let secret = outside.appendingPathComponent("secret")
        try Data([9]).write(to: secret)
        let symlinkRoot = parent.appendingPathComponent("alias.schneerunner")
        try fm.createSymbolicLink(at: symlinkRoot, withDestinationURL: root)
        #expect(throws: (any Error).self) { try CompanionPackDirectory(symlinkRoot) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("leaf"), withDestinationURL: secret)
        try fm.linkItem(at: secret, to: root.appendingPathComponent("hard"))
        let fifo = root.appendingPathComponent("pipe")
        let created = fifo.withUnsafeFileSystemRepresentation { path in
            path.map { mkfifo($0, 0o600) } ?? -1
        }
        try #require(created == 0)
        let directory = try CompanionPackDirectory(root)
        for name in ["alias/secret", "leaf", "hard", "pipe", "alias"] {
            let path = try CompanionPackPath(name)
            #expect(throws: (any Error).self) { try directory.read(path, maximumBytes: 32) }
        }
    }
}

@Test func packDescriptorStaysOnSelectedRootAfterPathReplacement() throws {
    try withPack { root, parent in
        let leaf = root.appendingPathComponent("frame")
        try Data([1]).write(to: leaf)
        let directory = try CompanionPackDirectory(root)
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data([2]).write(to: leaf)
        #expect(try directory.read(CompanionPackPath("frame"), maximumBytes: 2) == Data([1]))
    }
}
