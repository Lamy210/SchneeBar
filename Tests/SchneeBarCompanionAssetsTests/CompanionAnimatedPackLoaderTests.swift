import Foundation
import SchneeBarCompanionCore
@testable import SchneeBarCompanionAssets
import Testing

private let animations: [(kind: String, filename: String, base64: String)] = [
    ("gif", "run.gif", "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="),
    ("apng", "walk.png", "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAAEAAAAAgAAAAAAAAAAAAEACgAAdYjXEwAAABNJREFUeJxj/M/A8J8BCTAxoAEAPycCAuqcPLEAAAAaZmNUTAAAAAEAAAAEAAAAAgAAAAAAAAAAAAEABQAA5ad6+gAAABdmZEFUAAAAAnicY2Ro+P+fAQkwMaABAE0pAoJQdSdOAAAAAElFTkSuQmCC"),
    ("webP", "idle.webp", "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAwAAAQAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAMAAAEAAGQAAAJWUDhMDwAAAC8DQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAMAAAEAAMgAAABWUDhMEAAAAC8DQAAAB1DA6H//AxHR/wA=")
]

private func withAnimatedPack(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".schneerunner", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    for animation in animations {
        try #require(Data(base64Encoded: animation.base64))
            .write(to: url.appendingPathComponent(animation.filename))
    }
    try body(url)
}

private func writeManifest(_ entries: String, to url: URL) throws {
    try Data("""
    {"formatVersion":1,"name":"Test","defaultState":"run","clips":[\(entries)]}
    """.utf8).write(to: url.appendingPathComponent("character.json"))
}

private let gifEntry = #"{"state":"run","kind":"gif","path":"run.gif"}"#
private let apngEntry = #"{"state":"walk","kind":"apng","path":"walk.png"}"#
private let webpEntry = #"{"state":"idle","kind":"webP","path":"idle.webp"}"#

@Test func animatedPackDecodesGIFAPNGWebPAndFallback() throws {
    try withAnimatedPack { url in
        try writeManifest([gifEntry, apngEntry, webpEntry].joined(separator: ","), to: url)
        let result = try CompanionAnimatedPackLoader.load(url)
        let states: [CompanionState] = [.run, .walk, .idle]
        for state in states {
            let asset = result.asset(for: state)
            try #require(asset.frames.count == 2)
            #expect(asset.frames.allSatisfy { $0.width == 4 && $0.height == 2 })
            try #require(asset.clip.durations.count == 2)
            #expect(abs(asset.clip.durations[0] - 0.1) < 0.011)
            #expect(abs(asset.clip.durations[1] - 0.2) < 0.011)
        }
        #expect(Set(states.map { result.asset(for: $0).clip.revision }).count == 3)
        #expect(result.asset(for: .sprint).clip == result.asset(for: .run).clip)
    }
}

@Test func animatedPackFailsAggregateBudgetsBeforeReturningAnyCatalogue() throws {
    try withAnimatedPack { url in
        // Same file declared twice deliberately counts as two decoded clips.
        let second = #"{"state":"walk","kind":"gif","path":"run.gif"}"#
        try writeManifest(gifEntry + "," + second, to: url)
        let bytes = try #require(Data(base64Encoded: animations[0].base64)).count
        #expect(throws: CompanionAnimatedPackError.encodedBudget) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(bytes: bytes * 2 - 1))
        }
        #expect(throws: CompanionAnimatedPackError.frameBudget) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(frames: 3))
        }
        #expect(throws: CompanionAnimatedPackError.pixelBudget) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(pixels: 31))
        }
        let exact = try CompanionAnimatedPackLoader.load(url, limits: .init(bytes: bytes * 2, frames: 4, pixels: 32))
        #expect(exact.asset(for: .run).frames.count == 2)
        #expect(exact.asset(for: .walk).frames.count == 2)
    }
}

@Test func animatedPackRejectsMismatchedKindAndUnsupportedMixedPack() throws {
    try withAnimatedPack { url in
        try writeManifest(#"{"state":"run","kind":"apng","path":"run.gif"}"#, to: url)
        #expect(throws: CompanionAnimatedPackError.formatMismatch) {
            try CompanionAnimatedPackLoader.load(url)
        }
        let unsupported = #"{"state":"walk","kind":"pngSequence","path":"nonexistent"}"#
        try writeManifest(gifEntry + "," + unsupported, to: url)
        #expect(throws: CompanionAnimatedPackError.unsupportedKind) {
            try CompanionAnimatedPackLoader.load(url)
        }
    }
}

@Test func animatedPackRejectsInvalidLaterClipAndLoosenedPolicy() throws {
    try withAnimatedPack { url in
        try writeManifest(gifEntry + "," + apngEntry, to: url)
        try Data([0, 1, 2]).write(to: url.appendingPathComponent("walk.png"))
        #expect(throws: (any Error).self) { try CompanionAnimatedPackLoader.load(url) }
        #expect(throws: CompanionAnimatedPackError.invalidLimits) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(pixels: Int.max))
        }
    }
}
