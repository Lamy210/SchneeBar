import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import Testing

private func packJSON(_ entries: String, name: String = "Snow", version: Int = 1,
                      fallback: String = "run") -> Data {
    Data("""
    {"formatVersion":\(version),"name":"\(name)","defaultState":"\(fallback)","clips":[\(entries)]}
    """.utf8)
}

private let runClip = #"{"state":"run","kind":"gif","path":"clips/run.gif"}"#

@Test func packManifestRecognizesAllLegacyKinds() throws {
    for kind in ["singleImage", "spriteSheet4x2", "pngSequence", "gif", "apng", "webP"] {
        let data = packJSON(#"{"state":"run","kind":"\#(kind)","path":"clips/a"}"#)
        let manifest = try CompanionPackManifest.decode(data)
        #expect(manifest.defaultState == .run)
        #expect(manifest.clips.count == 1)
        #expect(manifest.clips.first?.kind.rawValue == kind)
        #expect(manifest.clips.first?.path.components == ["clips", "a"])
    }
}

@Test func packManifestRequiresVersionNameUniqueStatesAndDefault() {
    #expect(throws: CompanionPackError.unsupportedVersion) {
        try CompanionPackManifest.decode(packJSON(runClip, version: 2))
    }
    #expect(throws: CompanionPackError.invalidName) {
        try CompanionPackManifest.decode(packJSON(runClip, name: " Snow "))
    }
    #expect(throws: CompanionPackError.invalidClips) {
        try CompanionPackManifest.decode(packJSON(runClip + "," + runClip))
    }
    #expect(throws: CompanionPackError.invalidClips) {
        try CompanionPackManifest.decode(packJSON(runClip, fallback: "walk"))
    }
    #expect(throws: CompanionPackError.invalidClips) {
        try CompanionPackManifest.decode(packJSON(""))
    }
}

@Test func packPathRejectsTraversalAndUnboundedComponents() throws {
    for path in ["", "/tmp/file", "../file", "a/../b", "a/./b", "a//b", "a/",
                 "a\\b", "C:foo", "x\u{0}y", String(repeating: "a", count: 256),
                 Array(repeating: "a", count: 17).joined(separator: "/")] {
        #expect(throws: CompanionPackError.unsafePath) { try CompanionPackPath(path) }
    }
    #expect(try CompanionPackPath("素材/run.gif").components == ["素材", "run.gif"])
}

@Test func packManifestByteLimitAndInvalidUTF8() throws {
    var data = packJSON(runClip)
    data.append(Data(repeating: 32, count: CompanionPackManifest.maximumBytes - data.count))
    #expect(try CompanionPackManifest.decode(data).name == "Snow")
    data.append(32)
    #expect(throws: CompanionPackError.invalidManifest) { try CompanionPackManifest.decode(data) }
    #expect(throws: CompanionPackError.invalidManifest) { try CompanionPackManifest.decode(Data([0xff])) }
}
