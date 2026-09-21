import Foundation

public struct GitHubEnterpriseServerVersion: Codable, Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing rawValue: String) {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Self.leadingInteger(in: components[0]),
              let minor = Self.leadingInteger(in: components[1])
        else {
            return nil
        }

        let patch = components.count >= 3
            ? Self.leadingInteger(in: components[2]) ?? 0
            : 0

        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (
        lhs: GitHubEnterpriseServerVersion,
        rhs: GitHubEnterpriseServerVersion
    ) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func leadingInteger(in component: Substring) -> Int? {
        let digits = component.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

public enum GitHubEnterpriseCompatibility: String, Codable, Sendable {
    case tested
    case olderUntested
    case newerUntested
    case unknownVersion
}

public struct GitHubEnterpriseCompatibilityPolicy: Sendable {
    public let testedMajor: Int
    public let testedMinorRange: ClosedRange<Int>

    public init(
        testedMajor: Int = 3,
        testedMinorRange: ClosedRange<Int> = 20 ... 22
    ) {
        self.testedMajor = testedMajor
        self.testedMinorRange = testedMinorRange
    }

    public func compatibility(
        for version: GitHubEnterpriseServerVersion?
    ) -> GitHubEnterpriseCompatibility {
        guard let version else { return .unknownVersion }

        if version.major == testedMajor,
           testedMinorRange.contains(version.minor)
        {
            return .tested
        }

        let minimum = GitHubEnterpriseServerVersion(
            major: testedMajor,
            minor: testedMinorRange.lowerBound
        )
        return version < minimum ? .olderUntested : .newerUntested
    }
}

public struct GitHubEnterpriseMetadataRefreshPolicy: Sendable {
    public let minimumInterval: TimeInterval

    public init(
        minimumInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.minimumInterval = max(0, minimumInterval)
    }

    public func shouldRefresh(
        connection: GitHubConnection,
        lastCheckedAt: Date?,
        now: Date
    ) -> Bool {
        guard connection.deploymentKind == .enterpriseServer else {
            return false
        }
        guard let lastCheckedAt else {
            return true
        }
        return now.timeIntervalSince(lastCheckedAt) >= minimumInterval
    }
}

public struct GitHubEnterpriseServerDiscoveryResult: Equatable, Sendable {
    public let installedVersion: String
    public let parsedVersion: GitHubEnterpriseServerVersion?
    public let compatibility: GitHubEnterpriseCompatibility

    public init(
        installedVersion: String,
        parsedVersion: GitHubEnterpriseServerVersion?,
        compatibility: GitHubEnterpriseCompatibility
    ) {
        self.installedVersion = installedVersion
        self.parsedVersion = parsedVersion
        self.compatibility = compatibility
    }
}

public enum GitHubEnterpriseServerDiscoveryError: Error, Equatable, Sendable {
    case enterpriseServerConnectionRequired
    case httpStatus(Int)
    case invalidPayload
}

public struct GitHubEnterpriseServerDiscoveryClient: Sendable {
    private let transport: any GitHubHTTPTransport
    private let compatibilityPolicy: GitHubEnterpriseCompatibilityPolicy

    public init(
        transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport(),
        compatibilityPolicy: GitHubEnterpriseCompatibilityPolicy = .init()
    ) {
        self.transport = transport
        self.compatibilityPolicy = compatibilityPolicy
    }

    public func discover(
        connection: GitHubConnection
    ) async throws -> GitHubEnterpriseServerDiscoveryResult {
        guard connection.deploymentKind == .enterpriseServer else {
            throw GitHubEnterpriseServerDiscoveryError.enterpriseServerConnectionRequired
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let metaURL = endpoints.restBaseURL.appendingPathComponent("meta", isDirectory: false)
        var request = URLRequest(url: metaURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubEnterpriseServerDiscoveryError.httpStatus(response.statusCode)
        }

        let payload: MetaPayload
        do {
            payload = try JSONDecoder().decode(MetaPayload.self, from: data)
        } catch {
            throw GitHubEnterpriseServerDiscoveryError.invalidPayload
        }

        let parsedVersion = GitHubEnterpriseServerVersion(parsing: payload.installedVersion)
        return GitHubEnterpriseServerDiscoveryResult(
            installedVersion: payload.installedVersion,
            parsedVersion: parsedVersion,
            compatibility: compatibilityPolicy.compatibility(for: parsedVersion)
        )
    }
}

private struct MetaPayload: Decodable {
    let installedVersion: String

    private enum CodingKeys: String, CodingKey {
        case installedVersion = "installed_version"
    }
}
