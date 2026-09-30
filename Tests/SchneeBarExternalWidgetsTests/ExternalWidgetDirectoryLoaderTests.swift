import Darwin
import Foundation
import SchneeBarCore
@testable import SchneeBarExternalWidgets
import Testing

@Test
func missingExternalWidgetDirectoryLoadsAsEmptyCollection() async throws {
    let fixture = try LoaderDirectoryFixture(createRoot: false)
    defer { fixture.cleanup() }

    let loaded = try await ExternalWidgetDirectoryLoader(
        rootURL: fixture.rootURL
    ).load()

    #expect(loaded.isEmpty)
}

@Test
func loadsOnlyDirectJSONChildrenAndReturnsCanonicalIDOrder() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try fixture.write(
        document: loaderDocument(id: "external.zeta.build"),
        named: "a.json"
    )
    try fixture.write(
        document: loaderDocument(id: "external.alpha.build"),
        named: "z.json"
    )
    try Data("ignored".utf8).write(
        to: fixture.rootURL.appendingPathComponent("notes.txt")
    )

    let nested = fixture.rootURL.appendingPathComponent(
        "nested",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: false
    )
    try fixture.write(
        document: loaderDocument(id: "external.nested.build"),
        at: nested.appendingPathComponent("nested.json")
    )

    let loaded = try await ExternalWidgetDirectoryLoader(
        rootURL: fixture.rootURL
    ).load()

    #expect(
        loaded.map(\.descriptor.id.rawValue)
            == ["external.alpha.build", "external.zeta.build"]
    )
}

@Test
func rejectsSymlinkedOwnerDirectoryWithoutTraversingIt() async throws {
    let fixture = try LoaderDirectoryFixture(createRoot: false)
    let actualOwner = fixture.baseURL
        .deletingLastPathComponent()
        .appendingPathComponent(
            "SchneeBarExternalWidgetActualOwner-\(UUID().uuidString)",
            isDirectory: true
        )
    defer {
        fixture.cleanup()
        try? FileManager.default.removeItem(at: actualOwner)
    }

    try FileManager.default.createDirectory(
        at: actualOwner,
        withIntermediateDirectories: false
    )
    try FileManager.default.createDirectory(
        at: actualOwner.appendingPathComponent(
            "ExternalWidgets",
            isDirectory: true
        ),
        withIntermediateDirectories: false
    )
    try FileManager.default.removeItem(at: fixture.baseURL)
    try FileManager.default.createSymbolicLink(
        at: fixture.baseURL,
        withDestinationURL: actualOwner
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsSymlinkedRootDirectory() async throws {
    let fixture = try LoaderDirectoryFixture(createRoot: false)
    defer { fixture.cleanup() }

    let actual = fixture.baseURL.appendingPathComponent(
        "actual",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: actual,
        withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
        at: fixture.rootURL,
        withDestinationURL: actual
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsTrustedParentOwnedByUnexpectedUser() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let currentUID = Darwin.geteuid()
    let unexpectedUID: uid_t = currentUID == 0 ? 1 : 0

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL,
            expectedOwnerUID: unexpectedUID
        ).load()
    }
}

@Test(arguments: [0o775, 0o757])
func rejectsTrustedParentWritableByGroupOrOthers(
    permissions: Int
) async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: fixture.anchorURL.path
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test(arguments: [0o775, 0o757])
func rejectsOwnerDirectoryWritableByGroupOrOthers(
    permissions: Int
) async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: fixture.baseURL.path
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsRootDirectoryWithExtendedACL() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try addWriteACL(at: fixture.rootURL)

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func allowsReadOnlyExtendedACL() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try addACL(
        "everyone allow read",
        at: fixture.rootURL
    )

    let definitions = try await ExternalWidgetDirectoryLoader(
        rootURL: fixture.rootURL
    ).load()

    #expect(definitions.isEmpty)
}

@Test(arguments: [0o775, 0o757])
func rejectsRootDirectoryWritableByGroupOrOthers(
    permissions: Int
) async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: fixture.rootURL.path
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeRoot
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsSymlinkedJSONDocumentWithoutFollowingIt() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let outside = fixture.baseURL.appendingPathComponent("outside.json")
    try loaderDocumentData(id: "external.outside.build").write(to: outside)

    try FileManager.default.createSymbolicLink(
        at: fixture.rootURL.appendingPathComponent("linked.json"),
        withDestinationURL: outside
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeDocumentEntry
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsJSONDocumentWithExtendedACL() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let url = fixture.rootURL.appendingPathComponent("acl.json")
    try loaderDocumentData(id: "external.acl.build").write(to: url)
    try addWriteACL(at: url)

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeDocumentEntry
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test(arguments: [0o664, 0o646])
func rejectsJSONDocumentWritableByGroupOrOthers(
    permissions: Int
) async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let url = fixture.rootURL.appendingPathComponent("writable.json")
    try loaderDocumentData(id: "external.writable.build").write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: url.path
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeDocumentEntry
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsHardLinkedJSONDocument() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let outside = fixture.baseURL.appendingPathComponent("outside.json")
    try loaderDocumentData(id: "external.outside.build").write(to: outside)
    try FileManager.default.linkItem(
        at: outside,
        to: fixture.rootURL.appendingPathComponent("linked.json")
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeDocumentEntry
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsNonRegularJSONEntry() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try FileManager.default.createDirectory(
        at: fixture.rootURL.appendingPathComponent(
            "directory.json",
            isDirectory: true
        ),
        withIntermediateDirectories: false
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.unsafeDocumentEntry
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsUnsafeFilenameBeforeOpeningEntry() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try fixture.write(
        document: loaderDocument(id: "external.bad_name.build"),
        named: "bad\n.json"
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.invalidFilename
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsDirectoryEntryCountAboveBoundBeforeFilteringJSON() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    for index in 0 ... ExternalWidgetDirectoryLoader.maximumDirectoryEntryCount {
        try Data().write(
            to: fixture.rootURL.appendingPathComponent(
                "ignored-\(index).txt"
            )
        )
    }

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.tooManyDirectoryEntries
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsDocumentCountAboveBound() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    for index in 0 ... ExternalWidgetDirectoryLoader.maximumDocumentCount {
        try fixture.write(
            document: loaderDocument(
                id: "external.item_\(index).build"
            ),
            named: "\(index).json"
        )
    }

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.tooManyDocuments
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsSingleDocumentAboveByteBoundBeforeDecoding() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let data = Data(
        repeating: 0x20,
        count: ExternalWidgetDirectoryLoader.maximumDocumentBytes + 1
    )
    try data.write(
        to: fixture.rootURL.appendingPathComponent("oversized.json")
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.documentTooLarge
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsAggregateBytesAboveBound() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    let paddedSize = 60 * 1_024
    let documentCount = 9
    #expect(
        paddedSize < ExternalWidgetDirectoryLoader.maximumDocumentBytes
    )
    #expect(
        paddedSize * documentCount
            > ExternalWidgetDirectoryLoader.maximumAggregateBytes
    )

    for index in 0 ..< documentCount {
        var data = try loaderDocumentData(
            id: "external.aggregate_\(index).build"
        )
        #expect(data.count < paddedSize)
        data.append(
            Data(
                repeating: 0x20,
                count: paddedSize - data.count
            )
        )
        try data.write(
            to: fixture.rootURL.appendingPathComponent(
                "\(index).json"
            )
        )
    }

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.aggregateTooLarge
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsMalformedAndUnsupportedDocumentsWithoutReturningPartialData() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try fixture.write(
        document: loaderDocument(id: "external.good.build"),
        named: "a.json"
    )
    try Data("{".utf8).write(
        to: fixture.rootURL.appendingPathComponent("b.json")
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.invalidDocument
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }

    try FileManager.default.removeItem(
        at: fixture.rootURL.appendingPathComponent("b.json")
    )
    try fixture.write(
        document: loaderDocument(
            schemaVersion: 2,
            id: "external.unsupported.build"
        ),
        named: "c.json"
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.invalidDocument
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func rejectsDuplicateWidgetIDsAcrossDifferentFiles() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try fixture.write(
        document: loaderDocument(id: "external.duplicate.build"),
        named: "a.json"
    )
    try fixture.write(
        document: loaderDocument(id: "external.duplicate.build"),
        named: "b.json"
    )

    await #expect(
        throws: ExternalWidgetDirectoryLoaderError.invalidDocument
    ) {
        try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }
}

@Test
func preservesCancellationBeforeFilesystemWork() async throws {
    let fixture = try LoaderDirectoryFixture()
    defer { fixture.cleanup() }

    try fixture.write(
        document: loaderDocument(id: "external.cancel.build"),
        named: "widget.json"
    )

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        return try await ExternalWidgetDirectoryLoader(
            rootURL: fixture.rootURL
        ).load()
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

private enum LoaderACLFixtureError: Error {
    case chmodFailed(Int32)
}

private func addWriteACL(
    at url: URL
) throws {
    try addACL(
        "everyone allow write",
        at: url
    )
}

private func addACL(
    _ entry: String,
    at url: URL
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = [
        "+a",
        entry,
        url.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw LoaderACLFixtureError.chmodFailed(
            process.terminationStatus
        )
    }
}

private struct LoaderDirectoryFixture {
    let anchorURL: URL
    let baseURL: URL
    let rootURL: URL

    init(createRoot: Bool = true) throws {
        anchorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SchneeBarExternalWidgetLoaderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        baseURL = anchorURL.appendingPathComponent(
            "SchneeBar",
            isDirectory: true
        )
        rootURL = baseURL.appendingPathComponent(
            "ExternalWidgets",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: anchorURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: false
        )
        if createRoot {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false
            )
        }
    }

    func write(
        document: ExternalWidgetDocument,
        named name: String
    ) throws {
        try write(
            document: document,
            at: rootURL.appendingPathComponent(name)
        )
    }

    func write(
        document: ExternalWidgetDocument,
        at url: URL
    ) throws {
        try loaderDocumentData(document: document).write(
            to: url,
            options: .atomic
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: anchorURL)
    }
}

private func loaderDocument(
    schemaVersion: Int = 1,
    id: String
) -> ExternalWidgetDocument {
    ExternalWidgetDocument(
        schemaVersion: schemaVersion,
        id: id,
        displayName: "External Build",
        defaultEnabled: false,
        defaultOrder: 1_200,
        defaultRepresentation: .normal,
        visibility: ExternalWidgetVisibilityDocument(
            kind: .always
        ),
        refresh: ExternalWidgetRefreshDocument(
            kind: .manual
        ),
        snapshot: ExternalWidgetSnapshotDocument(
            severity: .nominal,
            priority: .normal,
            compact: ExternalWidgetContentDocument(
                text: "OK",
                systemImage: "checkmark.circle.fill",
                accessibilityLabel: "External build okay"
            ),
            normal: ExternalWidgetContentDocument(
                text: "External build okay",
                systemImage: "hammer",
                accessibilityLabel: "External build okay"
            )
        )
    )
}

private func loaderDocumentData(
    id: String
) throws -> Data {
    try loaderDocumentData(
        document: loaderDocument(id: id)
    )
}

private func loaderDocumentData(
    document: ExternalWidgetDocument
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
}
