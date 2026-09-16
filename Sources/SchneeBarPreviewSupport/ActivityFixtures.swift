import Foundation
import SchneeBarCore

public enum ActivityFixtureScenario: String, CaseIterable, Identifiable, Sendable {
    case normal
    case running
    case mainFailure
    case waiting
    case enterprise
    case overflow
    case mixedInbox
    case reviewOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .running: "Running"
        case .mainFailure: "Main Failure"
        case .waiting: "Waiting"
        case .enterprise: "Enterprise"
        case .overflow: "Overflow"
        case .mixedInbox: "GitHub Mixed Inbox"
        case .reviewOnly: "GitHub Review Only"
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
                .init(
                    id: "running-pr",
                    repository: "SchneeBar",
                    context: "PR #12",
                    detail: "macOS Build · 4/6 jobs",
                    state: .running,
                    destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/1200")
                ),
                .init(id: "running-release", repository: "SchneeMail", context: "main", detail: "Release · 01:42", state: .running),
                .init(id: "running-wait", repository: "Project A", context: "PR #731", detail: "Waiting for review", state: .waiting),
            ]
        case .mainFailure:
            [
                .init(
                    id: "failure-main",
                    repository: "SchneeBar",
                    context: "main",
                    detail: "macOS Tests failed · 2m ago",
                    state: .failed,
                    destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/1400")
                ),
                .init(
                    id: "failure-pr",
                    repository: "SchneeBar",
                    context: "PR #14",
                    detail: "CI · 7/10 jobs",
                    state: .running,
                    destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/1401")
                ),
                .init(id: "failure-other", repository: "SchneeAI", context: "main", detail: "CI passed · 5m ago", state: .success),
            ]
        case .waiting:
            [
                .init(id: "waiting-review", repository: "SchneeBar", context: "PR #21", detail: "Review requested · 8m ago", state: .waiting),
                .init(id: "waiting-approval", repository: "Company API", context: "PR #842", detail: "Waiting for approval", state: .waiting),
            ]
        case .enterprise:
            [
                .init(
                    id: "enterprise-cloud",
                    repository: "Company API",
                    context: "PR #843",
                    detail: "Review requested · GHE.com",
                    state: .waiting,
                    destinationURL: URL(string: "https://company.ghe.com/acme/api/actions/runs/843")
                ),
                .init(
                    id: "enterprise-ghes",
                    repository: "Internal Service",
                    context: "production",
                    detail: "Deploying · GHES",
                    state: .running,
                    destinationURL: URL(string: "https://github.internal.example:8443/acme/internal/actions/runs/844")
                ),
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
        case .mixedInbox:
            [
                ActivityItem(
                    id: "review-1",
                    repository: "snow-labs/frost",
                    context: "PR #142",
                    detail: "Review requested · Harden wake recovery",
                    state: .waiting,
                    destinationURL: URL(string: "https://github.com/snow-labs/frost/pull/142"),
                    kind: .reviewRequest,
                    attention: .actionRequired,
                    updatedAt: fixtureDate(300)
                ),
                ActivityItem(
                    id: "check-1",
                    repository: "snow-labs/frost",
                    context: "Codecov",
                    detail: "Failed · patch coverage",
                    state: .failed,
                    destinationURL: URL(string: "https://github.com/snow-labs/frost/commit/aaaaaaaa/checks"),
                    kind: .checkRun,
                    attention: .needsAttention,
                    updatedAt: fixtureDate(200)
                ),
                ActivityItem(
                    id: "workflow-1",
                    repository: "snow-labs/crystal",
                    context: "main · CI",
                    detail: "Running · Build",
                    state: .running,
                    destinationURL: URL(string: "https://github.com/snow-labs/crystal/actions/runs/123"),
                    kind: .workflowRun,
                    attention: .active,
                    updatedAt: fixtureDate(100)
                ),
            ]
        case .reviewOnly:
            [
                ActivityItem(
                    id: "review-only-1",
                    repository: "snow-labs/frost",
                    context: "PR #142",
                    detail: "Review requested · Harden wake recovery",
                    state: .waiting,
                    destinationURL: URL(string: "https://github.com/snow-labs/frost/pull/142"),
                    kind: .reviewRequest,
                    attention: .actionRequired,
                    updatedAt: fixtureDate(300)
                ),
                ActivityItem(
                    id: "review-only-2",
                    repository: "snow-labs/crystal",
                    context: "PR #87",
                    detail: "Review requested · Reduce launch latency",
                    state: .waiting,
                    destinationURL: URL(string: "https://github.com/snow-labs/crystal/pull/87"),
                    kind: .reviewRequest,
                    attention: .actionRequired,
                    updatedAt: fixtureDate(200)
                ),
            ]
        }
    }

    private func fixtureDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }
}
