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

public enum GitHubClientIDPolicy {
    public static let maximumCharacters = 256
    public static let maximumUTF8Bytes = 1_024

    public static func isValid(_ clientID: String) -> Bool {
        guard !clientID.isEmpty,
              clientID == clientID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              clientID.count <= maximumCharacters,
              clientID.utf8.count <= maximumUTF8Bytes,
              GitHubPresentationTextPolicy.hasSafeScalars(clientID)
        else {
            return false
        }
        return true
    }
}

public enum GitHubDeviceFlowResponsePolicy {
    // Device Flow/OAuth responses are expected to be small. These are generous
    // app-owned defensive budgets, not GitHub protocol maxima.
    public static let maximumResponseBytes = 256 * 1024
    public static let maximumOpaqueTokenCharacters = 16_384
    public static let maximumOpaqueTokenUTF8Bytes = 65_536
    public static let maximumOAuthErrorCodeCharacters = 256
    public static let maximumOAuthErrorCodeUTF8Bytes = 1_024
    public static let maximumOAuthErrorDescriptionCharacters = 4_096
    public static let maximumOAuthErrorDescriptionUTF8Bytes = 16_384

    public static func isValidOpaqueToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumOpaqueTokenCharacters
            && value.utf8.count <= maximumOpaqueTokenUTF8Bytes
    }

    public static func isValidOAuthErrorCode(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumOAuthErrorCodeCharacters
            && value.utf8.count <= maximumOAuthErrorCodeUTF8Bytes
            && GitHubPresentationTextPolicy.hasSafeScalars(value)
    }

    public static func isValidOAuthErrorDescription(
        _ value: String
    ) -> Bool {
        value.count <= maximumOAuthErrorDescriptionCharacters
            && value.utf8.count
                <= maximumOAuthErrorDescriptionUTF8Bytes
            && GitHubPresentationTextPolicy.hasSafeScalars(value)
    }
}

public enum GitHubDeviceFlowCredentialLifetimePolicy {
    // These are generous app-owned defensive budgets, not GitHub protocol
    // maxima. Current documented GitHub values are far below these ceilings.
    public static let maximumAccessTokenLifetime = 7 * 24 * 60 * 60
    public static let maximumRefreshTokenLifetime = 2 * 365 * 24 * 60 * 60

    public static func isValidAccessTokenLifetime(_ lifetime: Int) -> Bool {
        lifetime >= 1 && lifetime <= maximumAccessTokenLifetime
    }

    public static func isValidRefreshTokenLifetime(_ lifetime: Int) -> Bool {
        lifetime >= 1 && lifetime <= maximumRefreshTokenLifetime
    }
}

public enum GitHubDeviceFlowTimingPolicy {
    // App-owned defensive budgets, not GitHub protocol maxima.
    public static let maximumAuthorizationLifetime: TimeInterval = 86_400
    public static let maximumPollInterval: TimeInterval = 3_600

    public static func isValidAuthorizationLifetime(
        _ lifetime: TimeInterval
    ) -> Bool {
        lifetime.isFinite
            && lifetime >= 1
            && lifetime <= maximumAuthorizationLifetime
    }

    public static func isValidPollInterval(
        _ interval: TimeInterval
    ) -> Bool {
        interval.isFinite
            && interval >= 1
            && interval <= maximumPollInterval
    }

    public static func isValidSessionTiming(
        _ session: GitHubDeviceAuthorizationSession,
        now: Date
    ) -> Bool {
        guard session.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              isValidPollInterval(session.pollInterval)
        else {
            return false
        }

        let remaining = session.expiresAt.timeIntervalSince(now)
        return remaining.isFinite
            && remaining <= maximumAuthorizationLifetime
    }
}

public enum GitHubDeviceFlowCodePolicy {
    public static let maximumDeviceCodeCharacters = 4_096
    public static let maximumDeviceCodeUTF8Bytes = 16_384
    public static let maximumUserCodeCharacters = 128
    public static let maximumUserCodeUTF8Bytes = 512

    public static func isValidDeviceCode(_ deviceCode: String) -> Bool {
        !deviceCode.isEmpty
            && deviceCode.count <= maximumDeviceCodeCharacters
            && deviceCode.utf8.count <= maximumDeviceCodeUTF8Bytes
    }

    public static func isValidUserCode(_ userCode: String) -> Bool {
        !userCode.isEmpty
            && userCode == userCode.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && userCode.count <= maximumUserCodeCharacters
            && userCode.utf8.count <= maximumUserCodeUTF8Bytes
            && GitHubPresentationTextPolicy.hasSafeScalars(userCode)
    }
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
            let code = try validatedOAuthErrorCode(error)
            let description = try validatedOAuthErrorDescription(
                response.errorDescription
            )
            throw mappedOAuthError(
                code: code,
                description: description
            )
        }

        guard let deviceCode = response.deviceCode,
              let userCode = response.userCode,
              let rawVerificationURI = response.verificationURI,
              GitHubDeviceFlowCodePolicy.isValidDeviceCode(deviceCode),
              GitHubDeviceFlowCodePolicy.isValidUserCode(userCode)
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        let verificationURI = try validatedVerificationURI(
            rawVerificationURI,
            authenticationBaseURL: endpoints.authenticationBaseURL
        )
        let expiresIn = TimeInterval(response.expiresIn ?? 900)
        let interval = TimeInterval(response.interval ?? 5)
        guard GitHubDeviceFlowTimingPolicy
            .isValidAuthorizationLifetime(expiresIn),
            GitHubDeviceFlowTimingPolicy.isValidPollInterval(interval)
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        return GitHubDeviceAuthorizationSession(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            expiresAt: now().addingTimeInterval(expiresIn),
            pollInterval: interval
        )
    }

    public func pollOnce(
        connection: GitHubConnection,
        clientID: String,
        session: GitHubDeviceAuthorizationSession,
        repositoryID: String? = nil
    ) async throws -> GitHubDeviceFlowPollResult {
        let clientID = try validatedClientID(clientID)
        let referenceDate = now()
        guard GitHubDeviceFlowTimingPolicy.isValidSessionTiming(
            session,
            now: referenceDate
        ) else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        guard referenceDate < session.expiresAt else {
            return .expired
        }
        guard GitHubDeviceFlowCodePolicy.isValidDeviceCode(
            session.deviceCode
        ) else {
            throw GitHubDeviceFlowError.invalidResponse
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
        credential existingCredential: GitHubCredential
    ) async throws -> GitHubCredential {
        let clientID = try validatedClientID(clientID)
        guard let refreshToken = existingCredential.refreshToken,
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

        if payload.error != nil, payload.accessToken != nil {
            throw GitHubDeviceFlowError.invalidResponse
        }
        if let error = payload.error {
            let code = try validatedOAuthErrorCode(error)
            let description = try validatedOAuthErrorDescription(
                payload.errorDescription
            )
            throw mappedOAuthError(
                code: code,
                description: description
            )
        }
        return try issuedCredential(from: payload)
    }

    private func pollResult(
        from payload: TokenPayload,
        session: GitHubDeviceAuthorizationSession
    ) throws -> GitHubDeviceFlowPollResult {
        if payload.accessToken != nil, payload.error != nil {
            throw GitHubDeviceFlowError.invalidResponse
        }
        if payload.accessToken != nil {
            return .authorized(try issuedCredential(from: payload))
        }

        guard let rawError = payload.error else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        let error = try validatedOAuthErrorCode(rawError)
        _ = try validatedOAuthErrorDescription(
            payload.errorDescription
        )

        switch error {
        case "authorization_pending":
            return .pending(retryAfter: session.pollInterval)
        case "slow_down":
            let interval = payload.interval.map(TimeInterval.init)
                ?? (session.pollInterval + 5)
            guard GitHubDeviceFlowTimingPolicy
                .isValidPollInterval(interval)
            else {
                throw GitHubDeviceFlowError.invalidResponse
            }
            return .slowDown(retryAfter: interval)
        case "expired_token", "token_expired":
            return .expired
        case "access_denied":
            return .accessDenied
        default:
            throw mappedOAuthError(code: error, description: payload.errorDescription)
        }
    }

    private func issuedCredential(
        from payload: TokenPayload
    ) throws -> GitHubCredential {
        guard let tokenType = payload.tokenType,
              tokenType == tokenType.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              tokenType.caseInsensitiveCompare("bearer")
                == .orderedSame
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        switch (
            payload.expiresIn,
            payload.refreshToken,
            payload.refreshTokenExpiresIn
        ) {
        case (nil, nil, nil):
            // GitHub omits all expiration/refresh fields when user access
            // token expiration is disabled.
            return try credential(from: payload)

        case let (
            .some(accessTokenLifetime),
            .some(_),
            .some(refreshTokenLifetime)
        ):
            guard GitHubDeviceFlowCredentialLifetimePolicy
                .isValidAccessTokenLifetime(accessTokenLifetime),
                GitHubDeviceFlowCredentialLifetimePolicy
                    .isValidRefreshTokenLifetime(refreshTokenLifetime)
            else {
                throw GitHubDeviceFlowError.invalidResponse
            }
            return try credential(from: payload)

        default:
            throw GitHubDeviceFlowError.invalidResponse
        }
    }

    private func credential(from payload: TokenPayload) throws -> GitHubCredential {
        guard let accessToken = payload.accessToken,
              GitHubDeviceFlowResponsePolicy
                .isValidOpaqueToken(accessToken)
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        if let refreshToken = payload.refreshToken,
           !GitHubDeviceFlowResponsePolicy
            .isValidOpaqueToken(refreshToken)
        {
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

    private func validatedOAuthErrorCode(
        _ code: String
    ) throws -> String {
        guard GitHubDeviceFlowResponsePolicy
            .isValidOAuthErrorCode(code)
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        return code
    }

    private func validatedOAuthErrorDescription(
        _ description: String?
    ) throws -> String? {
        guard let description else {
            return nil
        }
        guard GitHubDeviceFlowResponsePolicy
            .isValidOAuthErrorDescription(description)
        else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        return description
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
        guard GitHubClientIDPolicy.isValid(clientID) else {
            throw GitHubDeviceFlowError.invalidClientID
        }
        return clientID
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
              effectiveHTTPSPort(verification.port) == effectiveHTTPSPort(expected.port),
              verification.user == nil,
              verification.password == nil
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
        GitHubRequestHeaderPolicy.apply(to: &request)
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
        guard data.count
            <= GitHubDeviceFlowResponsePolicy.maximumResponseBytes
        else {
            throw GitHubDeviceFlowError.invalidResponse
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