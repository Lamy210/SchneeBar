import Darwin
import Foundation
import SchneeBarCore
import Testing

@Test
func boundedRegularFileReaderReturnsNilForMissingFile() throws {
    let fixture = try boundedFileFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    #expect(
        try BoundedRegularFileReader.readIfPresent(
            at: fixture.fileURL,
            maximumBytes: 32
        ) == nil
    )
}

@Test
func boundedRegularFileReaderAcceptsExactByteLimit() throws {
    let fixture = try boundedFileFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try FileManager.default.createDirectory(
        at: fixture.directory,
        withIntermediateDirectories: true
    )
    let expected = Data(repeating: 0x61, count: 32)
    try expected.write(to: fixture.fileURL)

    let loaded = try BoundedRegularFileReader.readIfPresent(
        at: fixture.fileURL,
        maximumBytes: 32
    )

    #expect(loaded == expected)
}

@Test
func boundedRegularFileReaderRejectsPayloadBeyondByteLimit() throws {
    let fixture = try boundedFileFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try FileManager.default.createDirectory(
        at: fixture.directory,
        withIntermediateDirectories: true
    )
    try Data(repeating: 0x61, count: 33)
        .write(to: fixture.fileURL)

    #expect(
        throws: BoundedRegularFileReadError.payloadTooLarge
    ) {
        _ = try BoundedRegularFileReader.readIfPresent(
            at: fixture.fileURL,
            maximumBytes: 32
        )
    }
}

@Test
func boundedRegularFileReaderRejectsSymlinkAndHardLink() throws {
    for kind in ["symlink", "hardlink"] {
        let fixture = try boundedFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: true
        )
        let target = fixture.directory.appendingPathComponent(
            "target",
            isDirectory: false
        )
        try Data("safe".utf8).write(to: target)

        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(
                at: fixture.fileURL,
                withDestinationURL: target
            )
        } else {
            try FileManager.default.linkItem(
                at: target,
                to: fixture.fileURL
            )
        }

        #expect(
            throws: BoundedRegularFileReadError.unsafeBackingFile
        ) {
            _ = try BoundedRegularFileReader.readIfPresent(
                at: fixture.fileURL,
                maximumBytes: 32
            )
        }
    }
}

@Test
func boundedRegularFileReaderRejectsFIFOBeforeRead() throws {
    let fixture = try boundedFileFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try FileManager.default.createDirectory(
        at: fixture.directory,
        withIntermediateDirectories: true
    )
    let result = fixture.fileURL.path.withCString {
        Darwin.mkfifo($0, 0o600)
    }
    #expect(result == 0)

    #expect(
        throws: BoundedRegularFileReadError.unsafeBackingFile
    ) {
        _ = try BoundedRegularFileReader.readIfPresent(
            at: fixture.fileURL,
            maximumBytes: 32
        )
    }
}

private struct BoundedFileFixture {
    let directory: URL
    let fileURL: URL
}

private func boundedFileFixture() throws -> BoundedFileFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-bounded-file-\(UUID().uuidString)",
            isDirectory: true
        )
    return BoundedFileFixture(
        directory: directory,
        fileURL: directory.appendingPathComponent(
            "state.json",
            isDirectory: false
        )
    )
}
