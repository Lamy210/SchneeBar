import Foundation
import SchneeBarCore

public enum DeliveryHistoryFixtureScenario: String, CaseIterable, Identifiable {
    case mixedBranches = "mixed-branches"
    case neutralCompleted = "neutral-completed"
    case empty
    case requestFailure = "request-failure"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mixedBranches: "Mixed branches"
        case .neutralCompleted: "Neutral completed"
        case .empty: "Empty"
        case .requestFailure: "Request failure"
        }
    }

    public var repository: String {
        "Lamy210/SchneeBar"
    }

    public var history: DeliveryHistorySnapshot? {
        switch self {
        case .mixedBranches:
            DeliveryHistorySnapshot(
                repository: repository,
                entries: [
                    entry(
                        id: 812,
                        title: "CI",
                        detail: "Succeeded · Default branch · Run #812",
                        state: .success,
                        offset: 400
                    ),
                    entry(
                        id: 811,
                        title: "Release",
                        detail: "Failed · release/1.x · Run #811",
                        state: .failed,
                        offset: 300
                    ),
                    entry(
                        id: 810,
                        title: "CI",
                        detail: "Succeeded · feature/history · Run #810",
                        state: .success,
                        offset: 200
                    ),
                ]
            )
        case .neutralCompleted:
            DeliveryHistorySnapshot(
                repository: repository,
                entries: [
                    entry(
                        id: 809,
                        title: "CI",
                        detail: "Cancelled · main · Run #809",
                        state: .neutral,
                        offset: 300
                    ),
                    entry(
                        id: 808,
                        title: "Docs",
                        detail: "Skipped · docs/update · Run #808",
                        state: .neutral,
                        offset: 200
                    ),
                    entry(
                        id: 807,
                        title: "Nightly",
                        detail: "Stale · Branch unavailable · Run #807",
                        state: .neutral,
                        offset: 100
                    ),
                ]
            )
        case .empty:
            DeliveryHistorySnapshot(repository: repository, entries: [])
        case .requestFailure:
            nil
        }
    }

    public var errorMessage: String? {
        switch self {
        case .requestFailure:
            "Could not load delivery history."
        case .mixedBranches, .neutralCompleted, .empty:
            nil
        }
    }

    private func entry(
        id: Int64,
        title: String,
        detail: String,
        state: ActivityDetailState,
        offset: TimeInterval
    ) -> DeliveryHistoryEntry {
        DeliveryHistoryEntry(
            id: "github-actions:42:\(id)",
            title: title,
            detail: detail,
            state: state,
            destinationURL: URL(
                string: "https://github.com/Lamy210/SchneeBar/actions/runs/\(id)"
            ),
            occurredAt: Date(timeIntervalSince1970: 1_790_000_000 + offset)
        )
    }
}
