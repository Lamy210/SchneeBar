import SchneeBarCore

public enum ActivityFixtureScenario: String, CaseIterable, Identifiable, Sendable {
    case normal
    case running
    case mainFailure
    case waiting
    case enterprise
    case overflow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .running: "Running"
        case .mainFailure: "Main Failure"
        case .waiting: "Waiting"
        case .enterprise: "Enterprise"
        case .overflow: "Overflow"
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
        case .waiting:
            [
                .init(id: "waiting-review", repository: "SchneeBar", context: "PR #21", detail: "Review requested · 8m ago", state: .waiting),
                .init(id: "waiting-approval", repository: "Company API", context: "PR #842", detail: "Waiting for approval", state: .waiting),
            ]
        case .enterprise:
            [
                .init(id: "enterprise-cloud", repository: "Company API", context: "PR #843", detail: "Review requested · GHE.com", state: .waiting),
                .init(id: "enterprise-ghes", repository: "Internal Service", context: "production", detail: "Deploying · GHES", state: .running),
                .init(id: "enterprise-personal", repository: "SchneeBar", context: "main", detail: "CI passed · GitHub.com", state: .success),
            ]
        case .overflow:
            (1...14).map { index in
                ActivityItem(
                    id: "overflow-\(index)",
                    repository: "very-long-enterprise-repository-name-\(index)",
                    context: index.isMultiple(of: 2) ? "PR #\(800 + index)" : "release/2026.09.\(index)",
                    detail: "Long activity detail used to verify scrolling and truncation in constrained menu-bar popovers.",
                    state: index == 3 ? .failed : index.isMultiple(of: 3) ? .running : .success
                )
            }
        }
    }
}
