import Darwin
import Foundation

public enum ExternalWidgetDirectoryLoaderError:
    Error,
    Equatable,
    Sendable
{
    case unsafeRoot
    case rootUnavailable
    case tooManyDirectoryEntries
    case tooManyDocuments
    case invalidFilename
    case unsafeDocumentEntry
    case documentTooLarge
    case aggregateTooLarge
    case unreadableDocument
    case invalidDocument
}

public struct ExternalWidgetDirectoryLoader: Sendable {
    public static let maximumDirectoryEntryCount = 256
    public static let maximumDocumentCount = 32
    public static let maximumDocumentBytes = 64 * 1_024
    public static let maximumAggregateBytes = 512 * 1_024
    public static let maximumFilenameBytes = 255

    private let rootURL: URL
    private let adapter: ExternalWidgetDocumentAdapter

    public init() {
        rootURL = Self.defaultRootURL
        adapter = .init()
    }

    init(
        rootURL: URL,
        adapter: ExternalWidgetDocumentAdapter = .init()
    ) {
        self.rootURL = rootURL
        self.adapter = adapter
    }

    static var defaultRootURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )

        return applicationSupport
            .appendingPathComponent("SchneeBar", isDirectory: true)
            .appendingPathComponent(
                "ExternalWidgets",
                isDirectory: true
            )
    }

    public func load(
        now: Date = .now
    ) async throws -> [ExternalWidgetDefinition] {
        try Task.checkCancellation()

        guard let rootFileDescriptor = try openRootDirectory() else {
            return []
        }
        defer {
            Darwin.close(rootFileDescriptor)
        }

        let names = try directoryEntryNames(
            rootFileDescriptor: rootFileDescriptor
        )
        let jsonNames = try names
            .filter { ($0 as NSString).pathExtension == "json" }
            .map(validatedFilename)
            .sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }

        guard jsonNames.count <= Self.maximumDocumentCount else {
            throw ExternalWidgetDirectoryLoaderError.tooManyDocuments
        }

        var aggregateBytes = 0
        var documents: [ExternalWidgetDocument] = []
        documents.reserveCapacity(jsonNames.count)

        for name in jsonNames {
            try Task.checkCancellation()

            let data = try readDocument(
                named: name,
                relativeTo: rootFileDescriptor
            )

            aggregateBytes += data.count
            guard aggregateBytes <= Self.maximumAggregateBytes else {
                throw ExternalWidgetDirectoryLoaderError.aggregateTooLarge
            }

            let document: ExternalWidgetDocument
            do {
                document = try JSONDecoder().decode(
                    ExternalWidgetDocument.self,
                    from: data
                )
            } catch {
                throw ExternalWidgetDirectoryLoaderError.invalidDocument
            }
            documents.append(document)
        }

        try Task.checkCancellation()

        do {
            return try adapter.normalizeCollection(
                documents,
                now: now
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExternalWidgetDirectoryLoaderError.invalidDocument
        }
    }

    private func openRootDirectory() throws -> Int32? {
        let flags = O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        let fileDescriptor = rootURL.path.withCString {
            Darwin.open($0, flags)
        }

        if fileDescriptor >= 0 {
            return fileDescriptor
        }

        switch errno {
        case ENOENT:
            return nil
        case ELOOP, ENOTDIR:
            throw ExternalWidgetDirectoryLoaderError.unsafeRoot
        default:
            throw ExternalWidgetDirectoryLoaderError.rootUnavailable
        }
    }

    private func directoryEntryNames(
        rootFileDescriptor: Int32
    ) throws -> [String] {
        let duplicatedDescriptor = Darwin.dup(rootFileDescriptor)
        guard duplicatedDescriptor >= 0 else {
            throw ExternalWidgetDirectoryLoaderError.rootUnavailable
        }

        guard let directory = Darwin.fdopendir(duplicatedDescriptor) else {
            Darwin.close(duplicatedDescriptor)
            throw ExternalWidgetDirectoryLoaderError.rootUnavailable
        }
        defer {
            Darwin.closedir(directory)
        }

        var names: [String] = []
        errno = 0

        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) {
                    String(cString: $0)
                }
            }

            if name == "." || name == ".." {
                continue
            }
            names.append(name)
            guard names.count <= Self.maximumDirectoryEntryCount else {
                throw ExternalWidgetDirectoryLoaderError
                    .tooManyDirectoryEntries
            }
        }

        guard errno == 0 else {
            throw ExternalWidgetDirectoryLoaderError.rootUnavailable
        }
        return names
    }

    private func validatedFilename(
        _ name: String
    ) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              name == (name as NSString).lastPathComponent,
              name.utf8.count <= Self.maximumFilenameBytes,
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw ExternalWidgetDirectoryLoaderError.invalidFilename
        }
        return name
    }

    private func readDocument(
        named name: String,
        relativeTo rootFileDescriptor: Int32
    ) throws -> Data {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let fileDescriptor = name.withCString {
            Darwin.openat(rootFileDescriptor, $0, flags)
        }

        guard fileDescriptor >= 0 else {
            if errno == ELOOP {
                throw ExternalWidgetDirectoryLoaderError
                    .unsafeDocumentEntry
            }
            throw ExternalWidgetDirectoryLoaderError
                .unreadableDocument
        }
        defer {
            Darwin.close(fileDescriptor)
        }

        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0 else {
            throw ExternalWidgetDirectoryLoaderError.unreadableDocument
        }
        guard fileType(of: metadata) == mode_t(S_IFREG),
              metadata.st_nlink == 1
        else {
            throw ExternalWidgetDirectoryLoaderError
                .unsafeDocumentEntry
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(Self.maximumDocumentBytes)
        else {
            throw ExternalWidgetDirectoryLoaderError.documentTooLarge
        }

        return try readBounded(
            fileDescriptor: fileDescriptor,
            maximumBytes: Self.maximumDocumentBytes
        )
    }

    private func readBounded(
        fileDescriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(
            min(maximumBytes, 16 * 1_024)
        )

        var buffer = [UInt8](
            repeating: 0,
            count: 16 * 1_024
        )

        while true {
            try Task.checkCancellation()

            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else {
                throw ExternalWidgetDirectoryLoaderError.documentTooLarge
            }

            let readCount = buffer.withUnsafeMutableBytes {
                rawBuffer -> Int in
                Darwin.read(
                    fileDescriptor,
                    rawBuffer.baseAddress,
                    min(rawBuffer.count, remaining)
                )
            }

            if readCount == 0 {
                return data
            }

            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw ExternalWidgetDirectoryLoaderError
                    .unreadableDocument
            }

            data.append(contentsOf: buffer.prefix(readCount))
            if data.count > maximumBytes {
                throw ExternalWidgetDirectoryLoaderError.documentTooLarge
            }
        }
    }

    private func fileType(
        of metadata: stat
    ) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }
}
