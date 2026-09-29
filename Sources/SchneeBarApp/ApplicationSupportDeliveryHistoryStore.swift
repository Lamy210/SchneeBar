import Darwin
import Foundation
import SchneeBarCore

enum DeliveryHistoryStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidBackingFile
    case payloadTooLarge
}

actor ApplicationSupportDeliveryHistoryStore: DeliveryHistoryStoring {
    private static let maximumEntriesPerScope = 200
    private static let maximumScopes = 100
    // Internal defensive budget derived to stay well above the bounded
    // 100-scope / 200-entry cache while preventing an unbounded local read.
    private static let maximumPersistedBytes = 256 * 1024 * 1024

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let merger: DeliveryHistoryMerger

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.now = now
        merger = DeliveryHistoryMerger(
            maximumEntries: ApplicationSupportDeliveryHistoryStore.maximumEntriesPerScope
        )
    }

    func load(
        scope: DeliveryHistoryStorageScope
    ) async throws -> DeliveryHistorySnapshot? {
        try readPayload().records
            .first(where: { $0.scope == scope })?
            .snapshot
    }

    func save(
        _ snapshot: DeliveryHistorySnapshot,
        scope: DeliveryHistoryStorageScope
    ) async throws {
        var payload = try readPayload()
        let bounded = merger.merge(cached: nil, live: snapshot)
        let timestamp = now()

        if let index = payload.records.firstIndex(where: { $0.scope == scope }) {
            payload.records[index] = PersistedDeliveryHistoryRecord(
                scope: scope,
                updatedAt: timestamp,
                snapshot: bounded
            )
        } else {
            payload.records.append(
                PersistedDeliveryHistoryRecord(
                    scope: scope,
                    updatedAt: timestamp,
                    snapshot: bounded
                )
            )
        }

        payload.records = Array(
            payload.records
                .sorted(by: recordPrecedes)
                .prefix(Self.maximumScopes)
        )
        try writePayload(payload)
    }

    func delete(sourceID: String) async throws {
        var payload = try readPayload()
        let originalCount = payload.records.count
        payload.records.removeAll { $0.scope.sourceID == sourceID }
        guard payload.records.count != originalCount else { return }
        try writePayload(payload)
    }

    private func readPayload() throws -> PersistedDeliveryHistoryPayload {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return PersistedDeliveryHistoryPayload(
                schemaVersion: PersistedDeliveryHistoryPayload.currentSchemaVersion,
                records: []
            )
        }

        let data = try readPersistedData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            PersistedDeliveryHistoryPayload.self,
            from: data
        )
        guard payload.schemaVersion
            == PersistedDeliveryHistoryPayload.currentSchemaVersion
        else {
            throw DeliveryHistoryStoreError.unsupportedSchemaVersion(
                payload.schemaVersion
            )
        }
        return payload
    }

    private func readPersistedData() throws -> Data {
        var descriptor = Int32(-1)
        let hasFileSystemRepresentation =
            fileURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                descriptor = Darwin.open(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
                return true
            }
        guard hasFileSystemRepresentation else {
            throw DeliveryHistoryStoreError.invalidBackingFile
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DeliveryHistoryStoreError.invalidBackingFile
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw DeliveryHistoryStoreError.invalidBackingFile
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(Self.maximumPersistedBytes)
        else {
            throw DeliveryHistoryStoreError.payloadTooLarge
        }

        var data = Data()
        while data.count <= Self.maximumPersistedBytes {
            let remaining = Self.maximumPersistedBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= Self.maximumPersistedBytes else {
            throw DeliveryHistoryStoreError.payloadTooLarge
        }
        return data
    }

    private func writePayload(
        _ payload: PersistedDeliveryHistoryPayload
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)

        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func recordPrecedes(
        _ lhs: PersistedDeliveryHistoryRecord,
        _ rhs: PersistedDeliveryHistoryRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.scope.sourceID != rhs.scope.sourceID {
            return lhs.scope.sourceID < rhs.scope.sourceID
        }
        return lhs.scope.repositoryID < rhs.scope.repositoryID
    }

    private static func defaultFileURL(
        fileManager: FileManager
    ) -> URL {
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
                "delivery-history-v1.json",
                isDirectory: false
            )
    }
}

private struct PersistedDeliveryHistoryPayload: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var records: [PersistedDeliveryHistoryRecord]
}

private struct PersistedDeliveryHistoryRecord: Codable {
    let scope: DeliveryHistoryStorageScope
    let updatedAt: Date
    let snapshot: DeliveryHistorySnapshot
}
