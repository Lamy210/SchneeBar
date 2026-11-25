import Darwin
import Foundation
import SchneeBarCompanionAssets
import Testing

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test func boundedFileReadReturnsExactBytes() throws {
    try withTemporaryDirectory { root in
        let url = root.appendingPathComponent("local.png")
        let data = Data([0, 1, 2, 3, 255])
        try data.write(to: url)
        #expect(try CompanionFileReader.read(url) == data)
    }
}

@Test func boundedFileReadRejectsFinalSymlinkDirectoryAndFIFO() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("source")
        let link = root.appendingPathComponent("link")
        let pipe = root.appendingPathComponent("pipe")
        try Data([1]).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: CompanionFileReadError.openFailed) {
            try CompanionFileReader.read(link)
        }
        #expect(throws: CompanionFileReadError.notRegularFile) {
            try CompanionFileReader.read(root)
        }
        let status = pipe.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, mode_t(0o600))
        }
        try #require(status == 0)
        #expect(throws: CompanionFileReadError.notRegularFile) {
            try CompanionFileReader.read(pipe)
        }
    }
}

@Test func boundedFileReadRejectsEmptyOversizeAndNetworkURL() throws {
    try withTemporaryDirectory { root in
        let url = root.appendingPathComponent("oversize")
        try Data().write(to: url)
        #expect(throws: CompanionFileReadError.invalidSize) {
            try CompanionFileReader.read(url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(CompanionImageDecoder.maximumBytes + 1))
        #expect(throws: CompanionFileReadError.invalidSize) {
            try CompanionFileReader.read(url)
        }
    }
    let network = try #require(URL(string: "https://example.invalid/image.png"))
    #expect(throws: CompanionFileReadError.invalidURL) {
        try CompanionFileReader.read(network)
    }
}
