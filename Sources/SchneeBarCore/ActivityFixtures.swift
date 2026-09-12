public enum ActivityFixtureScenario: String, CaseIterable, Identifiable, Sendable {
    case normal
    case running
    case mainFailure
    case enterprise

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .running: "Running"
        case .mainFailure: "Main Failure"
        case .enterprise: "Enterprise"
        }
    }

    public var items: [ActivityItem] {
        switch self {
        case .normal:
            [
                .init(id: "normal-main", repository: "SchneeBar", context: "main", detail: "CI passed · 2m ago", state: .success),
                .init(id: "normal-pr", repository: "SchneeAI", context: "PR #42", detail: "Ready for review", state: .success),
            ]
        case .running:
            [
                .init(id: "running-pr", repository: "SchneeBar", context: "PR #12", detail: "macOS Build · 4/6 jobs", state: .running),
                .init(id: "running-release", repository: "SchneeMail", context: "main", detail: "Release · 01:42", state: .running),
                .init(id: "running-wait", repository: "Project A", context: "PR #731", detail: "Waiting for review", state: .waiting),
            ]
        case .mainFailure:
            [
                .init(id: "failure-main", repository: "SchneeBar", context: "main", detail: "macOS Tests failed · 2m ago", state: .failed),
                .init(id: "failure-pr", repository: "SchneeBar", context: "PR #14", detail: "CI · 7/10 jobs", state: .running),
                .init(id: "failure-other", repository: "SchneeAI", context: "main", detail: "CI passed · 5m ago", state: .success),
            ]
        case .enterprise:
            [
                .init(id: "enterprise-cloud", repository: "Company API", context: "PR #843", detail: "Review requested · GHE.com", state: .waiting),
                .init(id: "enterprise-ghes", repository: "Internal Service", context: "production", detail: "Deploying · GHES", state: .running),
                .init(id: "enterprise-personal", repository: "SchneeBar", context: "main", detail: "CI passed · GitHub.com", state: .success),
            ]
        }
    }
}
