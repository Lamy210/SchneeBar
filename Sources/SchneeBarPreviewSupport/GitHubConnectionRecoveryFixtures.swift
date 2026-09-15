import Foundation
import SchneeBarGitHubFeature

public enum GitHubConnectionRecoveryFixture {
    public static let context = GitHubConnectionRecoveryContext(
        connectionID: UUID(uuidString: "22000000-0000-0000-0000-000000000001")!,
        displayName: "Personal GitHub",
        host: "github.com",
        accountLogin: "snow-user"
    )

    public static let authorization = GitHubDeviceAuthorizationPresentation(
        userCode: "ABCD-EFGH",
        verificationURI: URL(string: "https://github.com/login/device")!,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
}
