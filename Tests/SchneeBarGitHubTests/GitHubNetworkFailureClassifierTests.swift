import Foundation
import SchneeBarGitHub
import Testing

@Test(arguments: [
    (URLError.Code.notConnectedToInternet, GitHubNetworkFailureKind.offline),
    (URLError.Code.cannotFindHost, GitHubNetworkFailureKind.hostResolution),
    (URLError.Code.dnsLookupFailed, GitHubNetworkFailureKind.hostResolution),
    (URLError.Code.cannotConnectToHost, GitHubNetworkFailureKind.connection),
    (URLError.Code.timedOut, GitHubNetworkFailureKind.timedOut),
    (URLError.Code.networkConnectionLost, GitHubNetworkFailureKind.connectionLost),
])
func classifiesExpectedNetworkFailures(
    code: URLError.Code,
    expected: GitHubNetworkFailureKind
) {
    let error = URLError(code)

    #expect(GitHubNetworkFailureClassifier.classify(error) == expected)
    #expect(GitHubNetworkFailureClassifier.isUnavailable(error))
}

@Test
func classifiesBridgedNSURLErrorDomainFailures() {
    let error = NSError(
        domain: NSURLErrorDomain,
        code: URLError.Code.cannotConnectToHost.rawValue
    )

    #expect(
        GitHubNetworkFailureClassifier.classify(error)
            == .connection
    )
}

@Test(arguments: [
    URLError.Code.secureConnectionFailed,
    URLError.Code.serverCertificateUntrusted,
    URLError.Code.clientCertificateRejected,
    URLError.Code.badServerResponse,
])
func doesNotCollapseSecurityOrProtocolFailuresIntoNetworkUnavailable(
    code: URLError.Code
) {
    let error = URLError(code)

    #expect(GitHubNetworkFailureClassifier.classify(error) == nil)
    #expect(!GitHubNetworkFailureClassifier.isUnavailable(error))
}

@Test
func ignoresUnrelatedErrors() {
    struct OtherError: Error {}

    #expect(GitHubNetworkFailureClassifier.classify(OtherError()) == nil)
}
