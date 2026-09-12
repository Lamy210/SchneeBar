import Foundation
import SchneeBarCore

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
}
