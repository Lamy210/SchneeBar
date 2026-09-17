import Foundation
import SchneeBarCore

public enum ActivityDetailFixtureScenario: String, CaseIterable, Identifiable {
    case failed
    case matrixSuccess = "matrix-success"
    case matrixFailure = "matrix-failure"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .failed: "Failed jobs"
        case .matrixSuccess: "Matrix success"
        case .matrixFailure: "Matrix failure"
        }
    }

    public var item: ActivityItem {
        ActivityDetailFixture.item
    }

    public var detail: ActivityDetailSnapshot {
        switch self {
        case .failed: ActivityDetailFixture.detail
        case .matrixSuccess: ActivityDetailFixture.matrixSuccess
        case .matrixFailure: ActivityDetailFixture.matrixFailure
        }
    }
}

public enum ActivityDetailFixture {
    public static let item = ActivityItem(
        id: "github-actions:42:501",
        repository: "Lamy210/SchneeBar",
        context: "PR #25 · CI",
        detail: "Failed · build-and-test",
        state: .failed,
        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501")
    )

    public static let detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: item.context,
        summary: "4/6 jobs · 2 failed · 1 running · 1 waiting",
        state: .failed,
        destinationURL: item.destinationURL,
        rows: [
            ActivityDetailRow(
                id: "7001",
                title: "Tests (macos-26, swift-6.3)",
                detail: "Failed at Test",
                state: .failed,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7001")
            ),
            ActivityDetailRow(
                id: "7002",
                title: "Linux (swift-6.3)",
                detail: "Timed out · 12m 0s",
                state: .failed,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7002")
            ),
            ActivityDetailRow(
                id: "7003",
                title: "Windows",
                detail: "Running",
                state: .running,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7003")
            ),
            ActivityDetailRow(
                id: "7004",
                title: "Integration",
                detail: "Waiting",
                state: .waiting,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7004")
            ),
            ActivityDetailRow(
                id: "7005",
                title: "Docs",
                detail: "Succeeded · 9s",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7005")
            ),
            ActivityDetailRow(
                id: "7006",
                title: "Lint",
                detail: "Cancelled",
                state: .neutral,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7006")
            ),
        ]
    )

    public static let matrixSuccess = ActivityDetailSnapshot(
        id: "github-actions:42:501:matrix-success",
        repository: item.repository,
        title: item.context,
        summary: "4/4 jobs",
        state: .success,
        destinationURL: item.destinationURL,
        rows: [
            ActivityDetailRow(
                id: "github-job-group:501:Test",
                title: "Test",
                detail: "3 variants",
                state: .success,
                children: [
                    ActivityDetailRow(
                        id: "7101",
                        title: "macos",
                        detail: "Succeeded · 42s",
                        state: .success,
                        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7101")
                    ),
                    ActivityDetailRow(
                        id: "7102",
                        title: "linux",
                        detail: "Succeeded · 31s",
                        state: .success,
                        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7102")
                    ),
                    ActivityDetailRow(
                        id: "7103",
                        title: "windows",
                        detail: "Succeeded · 58s",
                        state: .success,
                        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7103")
                    ),
                ]
            ),
            ActivityDetailRow(
                id: "7190",
                title: "Docs",
                detail: "Succeeded · 9s",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7190")
            ),
        ]
    )

    public static let matrixFailure = ActivityDetailSnapshot(
        id: "github-actions:42:501:matrix-failure",
        repository: item.repository,
        title: item.context,
        summary: "2/4 jobs · 1 failed · 1 running · 1 waiting",
        state: .failed,
        destinationURL: item.destinationURL,
        rows: [
            ActivityDetailRow(
                id: "github-job-group:501:Test",
                title: "Test",
                detail: "3 variants · 1 failed · 1 running · 1 waiting",
                state: .failed,
                children: [
                    ActivityDetailRow(
                        id: "7201",
                        title: "macos",
                        detail: "Failed at Unit tests",
                        state: .failed,
                        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7201")
                    ),
                    ActivityDetailRow(
                        id: "7202",
                        title: "linux",
                        detail: "Running",
                        state: .running,
                        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7202")
                    ),
                    ActivityDetailRow(
                        id: "7203",
                        title: "windows",
                        detail: "Waiting",
                        state: .waiting,
                        destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7203")
                    ),
                ]
            ),
            ActivityDetailRow(
                id: "7290",
                title: "Docs",
                detail: "Succeeded · 9s",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501/job/7290")
            ),
        ]
    )
}
