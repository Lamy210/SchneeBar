import Foundation

public enum GitHubEndpointResolverError: Error, Equatable, Sendable {
    case httpsRequired
    case missingHost
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
    case pathNotAllowed
    case nonStandardPortNotAllowed
    case invalidGitHubDotComHost
    case invalidGHEHost
}

public enum GitHubEndpointResolver {
    public static func resolve(
        deploymentKind: GitHubDeploymentKind,
        webBaseURL: URL
    ) throws -> GitHubEndpointSet {
        let canonicalWebURL = try canonicalize(
            webBaseURL,
            deploymentKind: deploymentKind
        )
        let components = try requireComponents(canonicalWebURL)
        let host = try requireHost(canonicalWebURL)

        switch deploymentKind {
        case .githubDotCom:
            guard host.caseInsensitiveCompare("github.com") == .orderedSame else {
                throw GitHubEndpointResolverError.invalidGitHubDotComHost
            }

            return GitHubEndpointSet(
                webBaseURL: canonicalWebURL,
                restBaseURL: try makeURL(scheme: "https", host: "api.github.com"),
                graphQLURL: try makeURL(scheme: "https", host: "api.github.com", path: "/graphql"),
                authenticationBaseURL: canonicalWebURL
            )

        case .gheDotCom:
            let lowercasedHost = host.lowercased()
            guard isValidGHEWebHost(lowercasedHost) else {
                throw GitHubEndpointResolverError.invalidGHEHost
            }

            return GitHubEndpointSet(
                webBaseURL: canonicalWebURL,
                restBaseURL: try makeURL(scheme: "https", host: "api.\(lowercasedHost)"),
                graphQLURL: try makeURL(
                    scheme: "https",
                    host: "api.\(lowercasedHost)",
                    path: "/graphql"
                ),
                authenticationBaseURL: canonicalWebURL
            )

        case .enterpriseServer:
            return GitHubEndpointSet(
                webBaseURL: canonicalWebURL,
                restBaseURL: try makeURL(
                    scheme: "https",
                    host: host,
                    port: components.port,
                    path: "/api/v3"
                ),
                graphQLURL: try makeURL(
                    scheme: "https",
                    host: host,
                    port: components.port,
                    path: "/api/graphql"
                ),
                authenticationBaseURL: canonicalWebURL
            )
        }
    }

    private static func canonicalize(
        _ url: URL,
        deploymentKind: GitHubDeploymentKind
    ) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GitHubEndpointResolverError.missingHost
        }
        guard components.scheme?.lowercased() == "https" else {
            throw GitHubEndpointResolverError.httpsRequired
        }
        guard components.host?.isEmpty == false else {
            throw GitHubEndpointResolverError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw GitHubEndpointResolverError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw GitHubEndpointResolverError.queryOrFragmentNotAllowed
        }

        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" else {
            throw GitHubEndpointResolverError.pathNotAllowed
        }

        if deploymentKind != .enterpriseServer {
            guard components.port == nil || components.port == 443 else {
                throw GitHubEndpointResolverError.nonStandardPortNotAllowed
            }
            components.port = nil
        }

        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let canonicalURL = components.url else {
            throw GitHubEndpointResolverError.missingHost
        }
        return canonicalURL
    }

    private static func isValidGHEWebHost(_ host: String) -> Bool {
        let labels = host.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard labels.count == 3,
              labels[1] == "ghe",
              labels[2] == "com"
        else {
            return false
        }

        let tenant = labels[0]
        return !tenant.isEmpty
            && tenant != "api"
            && tenant != "auth"
    }

    private static func requireComponents(_ url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GitHubEndpointResolverError.missingHost
        }
        return components
    }

    private static func requireHost(_ url: URL) throws -> String {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
              !host.isEmpty
        else {
            throw GitHubEndpointResolverError.missingHost
        }
        return host
    }

    private static func makeURL(
        scheme: String,
        host: String,
        port: Int? = nil,
        path: String = ""
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path

        guard let url = components.url else {
            throw GitHubEndpointResolverError.missingHost
        }
        return url
    }
}
