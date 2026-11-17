import CoreGraphics
import Foundation
import SchneeBarCompanionCore
@testable import SchneeBarCompanionAssets
import Testing

private let frame2 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAE0lEQVR4nGNU0DjxnwEJMDGgAQA/oAITy77fRgAAAABJRU5ErkJggg=="
private let frame10 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAE0lEQVR4nGM8oXHiPwMSYGJAAwBVSAK760l2QwAAAABJRU5ErkJggg=="
private let smallFrame = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAE0lEQVR4nGM0EuH6zwAFTAxIAAAd4AFTADfc1gAAAABJRU5ErkJggg=="

private func sequenceFixture(_ body: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".schneerunner", isDirectory: true)
    let frames = root.appendingPathComponent("frames", isDirectory: true)
    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Deliberately write in reverse numeric order.
    try #require(Data(base64Encoded: frame10)).write(to: frames.appendingPathComponent("frame10.PNG"))
    try #require(Data(base64Encoded: frame2)).write(to: frames.appendingPathComponent("frame2.png"))
    try Data("ignored".utf8).write(to: frames.appendingPathComponent(".hidden"))
    try Data(#"{"formatVersion":1,"name":"Sequence","defaultState":"run","clips":[{"state":"run","kind":"pngSequence","path":"frames"}]}"#.utf8)
        .write(to: root.appendingPathComponent("character.json"))
    try body(root, frames)
}

private func red(_ image: CGImage) throws -> UInt8 {
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes {
        let context = try #require(CGContext(data: $0.baseAddress, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes[0]
}

@Test func pngSequenceUsesNumericOrderAndDefaultFallback() throws {
    try sequenceFixture { root, _ in
        let catalog = try CompanionAnimatedPackLoader.load(root)
        let clip = catalog.asset(for: .run)
        try #require(clip.frames.count == 2)
        #expect(clip.frames.allSatisfy { $0.width == 4 && $0.height == 2 })
        #expect(abs(Int(try red(clip.frames[0])) - 32) <= 3)
        #expect(abs(Int(try red(clip.frames[1])) - 200) <= 3)
        #expect(clip.clip.durations == [1.0 / 12.0, 1.0 / 12.0])
        #expect(catalog.asset(for: .dash).clip == clip.clip)
    }
}

@Test func pngSequenceConsumesSharedBudgetAndRejectsUnequalDimensions() throws {
    try sequenceFixture { root, frames in
        #expect(throws: CompanionAnimatedPackError.frameBudget) {
            try CompanionAnimatedPackLoader.load(root, limits: .init(frames: 1))
        }
        #expect(throws: CompanionAnimatedPackError.pixelBudget) {
            try CompanionAnimatedPackLoader.load(root, limits: .init(pixels: 15))
        }
        let exact = try CompanionAnimatedPackLoader.load(root, limits: .init(frames: 2, pixels: 16))
        #expect(exact.asset(for: .run).frames.count == 2)
        try #require(Data(base64Encoded: smallFrame)).write(to: frames.appendingPathComponent("frame10.PNG"))
        #expect(throws: CompanionAnimatedPackError.inconsistentFrameDimensions) {
            try CompanionAnimatedPackLoader.load(root)
        }
    }
}

@Test func pngSequenceRejectsNonPNGVisibleEntryAndSymlink() throws {
    try sequenceFixture { root, frames in
        let junk = frames.appendingPathComponent("readme.txt")
        try Data([1]).write(to: junk)
        #expect(throws: CompanionAnimatedPackError.formatMismatch) {
            try CompanionAnimatedPackLoader.load(root)
        }
        try FileManager.default.removeItem(at: junk)
        try FileManager.default.createSymbolicLink(at: frames.appendingPathComponent("frame3.png"),
            withDestinationURL: frames.appendingPathComponent("frame2.png"))
        #expect(throws: (any Error).self) { try CompanionAnimatedPackLoader.load(root) }
    }
}

@Test func pngSequenceScanCapIncludesHiddenEntries() throws {
    try sequenceFixture { root, frames in
        for index in 0..<257 {
            try Data([1]).write(to: frames.appendingPathComponent(".hidden-\(index)"))
        }
        #expect(throws: CompanionAnimatedPackError.frameBudget) {
            try CompanionAnimatedPackLoader.load(root)
        }
    }
}
