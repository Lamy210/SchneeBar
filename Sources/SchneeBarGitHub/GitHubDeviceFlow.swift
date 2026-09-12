import Foundation

public struct GitHubDeviceAuthorizationSession: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresAt: Date
    public let pollInterval: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        expiresAt: Date,
        pollInterval: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
        self.pollInterval = pollInterval
    }
}

public enum GitHubDeviceFlowPollResult: Equatable, Sendable {
    case pending(retryAfter: TimeInterval)
    case slowDown(retryAfter: TimeInterval)
    case authorized(GitHubCredential)
    case accessDenied
    case expired
}

public enum GitHubDeviceFlowError: Error, Equatable, Sendable {
    case invalidClientID
    case missingRefreshToken
    case httpStatus(Int)
    case invalidResponse
    case untrustedVerificationURI
    case deviceFlowDisabled
    case incorrectClientCredentials
    case incorrectDeviceCode
    case unsupportedGrantType
    case oauth(code: String, description: String?)
}

public struct GitHubDeviceFlowClient: Sendable {
    private let transport: any GitHubHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.now = now
    }

    public func begin(
        connection: GitHubConnection,
        clientID: String
    ) async throws -> GitHubDeviceAuthorizationSession {
        let clientID = try validatedClientID(clientID)
        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.authenticationBaseURL
            .appendingPathComponent("login/device/code", isDirectory: false)

        let response: DeviceCodePayload = try await postForm(
            url: url,
            parameters: ["client_id": clientID]
        )
        if let error = response.error {
            throw mappedOAuthError(code: error, description: response.errorDescription)
        }

        guard let deviceCode = response.deviceCode,
              let userCode = response.userCode,
              let rawVerificationURI = response.verificationURI,
              !deviceCode.isEmpty,
              !userCode.isEmpty
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        let verificationURI = try validatedVerificationURI(
            rawVerificationURI,
            authenticationBaseURL: endpoints.authenticationBaseURL
        )
        let expiresIn = max(1, response.expiresIn ?? 900)
        let interval = max(1, response.interval ?? 5)

        return GitHubDeviceAuthorizationSession(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            pollInterval: TimeInterval(interval)
        )
    }

    public func pollOnce(
        connection: GitHubConnection,
        clientID: String,
        session: GitHubDeviceAuthorizationSession,
        repositoryID: String? = nil
    ) async throws -> GitHubDeviceFlowPollResult {
        let clientID = try validatedClientID(clientID)
        guard now() < session.expiresAt else {
            return .expired
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.authenticationBaseURL
            .appendingPathComponent("login/oauth/access_token", isDirectory: false)

        var parameters = [
            "client_id": clientID,
            "device_code": session.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
        if let repositoryID, !repositoryID.isEmpty {
            parameters["repository_id"] = repositoryID
        }

        let payload: TokenPayload = try await postForm(
            url: url,
            parameters: parameters
        )
        return try pollResult(from: payload, session: session)
    }

    public func refresh(
        connection: GitHubConnection,
        clientID: String,
        credential: GitHubCredential
    ) async throws -> GitHubCredential {
        let clientID = try validatedClientID(clientID)
        guard let refreshToken = credential.refreshToken,
              !refreshToken.isEmpty
        else {
            throw GitHubDeviceFlowError.missingRefreshToken
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.authenticationBaseURL
            .appendingPathComponent("login/oauth/access_token", isDirectory: false)

        let payload: TokenPayload = try await postForm(
            url: url,
            parameters: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )

        if let error = payload.error {
            throw mappedOAuthError(code: error, description: payload.errorDescription)
        }
        return try credential(from: payload)
    }

    private func pollResult(
        from payload: TokenPayload,
        session: GitHubDeviceAuthorizationSession
    ) throws -> GitHubDeviceFlowPollResult {
        if payload.accessToken != nil {
            return .authorized(try credential(from: payload))
        }

        guard let error = payload.error else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        switch error {
        case "authorization_pending":
            return .pending(retryAfter: session.pollInterval)
        case "slow_down":
            let interval = payload.interval.map { TimeInterval($0) }
                ?? (session.pollInterval + 5)
            return .slowDown(retryAfter: max(1, interval))
        case "expired_token", "token_expired":
            return .expired
        case "access_denied":
            return .accessDenied
        default:
            throw mappedOAuthError(code: error, description: payload.errorDescription)
        }
    }

    private func credential(from payload: TokenPayload) throws -> GitHubCredential {
        guard let accessToken = payload.accessToken,
              !accessToken.isEmpty
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        let referenceDate = now()
        return GitHubCredential(
            accessToken: accessToken,
            refreshToken: payload.refreshToken,
            accessTokenExpiresAt: payload.expiresIn.map {
                referenceDate.addingTimeInterval(TimeInterval($0))
            },
            refreshTokenExpiresAt: payload.refreshTokenExpiresIn.map {
                referenceDate.addingTimeInterval(TimeInterval($0))
            }
        )
    }

    private func mappedOAuthError(
        code: String,
        description: String?
    ) -> GitHubDeviceFlowError {
        switch code {
        case "device_flow_disabled":
            .deviceFlowDisabled
        case "incorrect_client_credentials":
            .incorrectClientCredentials
        case "incorrect_device_code":
            .incorrectDeviceCode
        case "unsupported_grant_type":
            .unsupportedGrantType
        default:
            .oauth(code: code, description: description)
        }
    }

    private func validatedClientID(_ clientID: String) throws -> String {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitHubDeviceFlowError.invalidClientID
        }
        return trimmed
    }

    private func validatedVerificationURI(
        _ rawValue: String,
        authenticationBaseURL: URL
    ) throws -> URL {
        guard let url = URL(string: rawValue),
              let verification = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(
                  url: authenticationBaseURL,
                  resolvingAgainstBaseURL: false
              ),
              verification.scheme?.lowercased() == "https",
              verification.host?.lowercased() == expected.host?.lowercased(),
              effectiveHTTPSPort(verification.port) == effectiveHTTPSPort(expected.port)
        else {
            throw GitHubDeviceFlowError.untrustedVerificationURI
        }
        return url
    }

    private func effectiveHTTPSPort(_ port: Int?) -> Int {
        port ?? 443
    }

    private func postForm<Response: Decodable>(
        url: URL,
        parameters: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formEncoded(parameters)

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubDeviceFlowError.httpStatus(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubDeviceFlowError.invalidResponse
        }
    }

    private func formEncoded(_ parameters: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

private struct DeviceCodePayload: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let expiresIn: Int?
    let interval: Int?
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
        case error
        case errorDescription = "error_description"
    }
}

private struct TokenPayload: Decodable {
    let accessToken: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let tokenType: String?
    let error: String?
    let errorDescription: String?
    let interval: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case tokenType = "token_type"
        case error
        case errorDescription = "error_description"
        case interval
    }
}
