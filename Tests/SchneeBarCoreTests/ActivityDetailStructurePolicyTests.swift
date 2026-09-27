import Foundation
import SchneeBarCore
import Testing

@Test
func detailStructureAcceptsCurrentMatrixShape() {
    let item = structureItem()
    let detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: "CI",
        summary: "3 jobs",
        state: .success,
        actions: [.rerunWorkflow],
        rows: [
            ActivityDetailRow(
                id: "matrix:tests:macos",
                title: "Tests",
                state: .success,
                children: [
                    ActivityDetailRow(
                        id: "7001",
                        title: "macOS 15",
                        state: .success
                    ),
                    ActivityDetailRow(
                        id: "7002",
                        title: "macOS 16",
                        state: .success
                    ),
                ]
            ),
            ActivityDetailRow(
                id: "7003",
                title: "Lint",
                state: .success
            ),
        ]
    )

    #expect(
        ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsMismatchedSnapshotIdentity() {
    let item = structureItem()
    let wrongID = ActivityDetailSnapshot(
        id: "github-actions:1:999",
        repository: item.repository,
        title: "CI",
        summary: "1 job",
        state: .success,
        rows: []
    )
    let wrongRepository = ActivityDetailSnapshot(
        id: item.id,
        repository: "other/repo",
        title: "CI",
        summary: "1 job",
        state: .success,
        rows: []
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            wrongID,
            selectedItem: item
        )
    )
    #expect(
        !ActivityDetailStructurePolicy.allows(
            wrongRepository,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsDuplicateTopLevelRows() {
    let item = structureItem()
    let detail = structureDetail(
        item: item,
        rows: [
            structureRow(id: "job"),
            structureRow(id: "job"),
        ]
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsDuplicateChildRows() {
    let item = structureItem()
    let detail = structureDetail(
        item: item,
        rows: [
            ActivityDetailRow(
                id: "group",
                title: "Group",
                state: .success,
                children: [
                    structureRow(id: "job"),
                    structureRow(id: "job"),
                ]
            ),
        ]
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureAllowsSameIDInUnrelatedSiblingCollections() {
    let item = structureItem()
    let detail = structureDetail(
        item: item,
        rows: [
            ActivityDetailRow(
                id: "group-a",
                title: "Group A",
                state: .success,
                children: [structureRow(id: "job")]
            ),
            ActivityDetailRow(
                id: "group-b",
                title: "Group B",
                state: .success,
                children: [structureRow(id: "job")]
            ),
        ]
    )

    #expect(
        ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsDepthThree() {
    let item = structureItem()
    let grandchild = structureRow(id: "grandchild")
    let child = ActivityDetailRow(
        id: "child",
        title: "Child",
        state: .success,
        children: [grandchild]
    )
    let parent = ActivityDetailRow(
        id: "parent",
        title: "Parent",
        state: .success,
        children: [child]
    )
    let detail = structureDetail(item: item, rows: [parent])

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test(arguments: [
    "",
    "unsafe\nidentifier",
    String(repeating: "a", count: 257),
])
func detailStructureRejectsInvalidRowIdentity(
    id: String
) {
    let item = structureItem()
    let detail = structureDetail(
        item: item,
        rows: [structureRow(id: id)]
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureAcceptsExactIdentityByteLimit() {
    let item = structureItem()
    let detail = structureDetail(
        item: item,
        rows: [
            structureRow(
                id: String(repeating: "a", count: 256)
            ),
        ]
    )

    #expect(
        ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsDuplicateTimelineEventIdentities() {
    let item = structureItem()
    let detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: "CI",
        summary: "Delivery",
        state: .success,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: "event",
                    kind: .execution,
                    title: "Run",
                    state: .success
                ),
                DeliveryTimelineEvent(
                    id: "event",
                    kind: .deployment,
                    title: "Deploy",
                    state: .success
                ),
            ]
        ),
        rows: []
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsDuplicateTimelineEvidenceIdentities() {
    let item = structureItem()
    let detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: "CI",
        summary: "Delivery",
        state: .success,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [],
            evidence: [
                DeliveryTimelineEvidenceItem(
                    id: "evidence",
                    title: "Commit",
                    state: .confirmed
                ),
                DeliveryTimelineEvidenceItem(
                    id: "evidence",
                    title: "PR",
                    state: .confirmed
                ),
            ]
        ),
        rows: []
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsInvalidTimelineIdentity() {
    let item = structureItem()
    let detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: "CI",
        summary: "Delivery",
        state: .success,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: String(repeating: "a", count: 257),
                    kind: .execution,
                    title: "Run",
                    state: .success
                ),
            ]
        ),
        rows: []
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func detailStructureRejectsDuplicateActions() {
    let item = structureItem()
    let detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: "CI",
        summary: "Actions",
        state: .failed,
        actions: [.rerunWorkflow, .rerunWorkflow],
        rows: []
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            detail,
            selectedItem: item
        )
    )
}

@Test
func historyStructureRequiresSelectedRepositoryAndUniqueIDs() {
    let item = structureItem()
    let mismatch = DeliveryHistorySnapshot(
        repository: "other/repo",
        entries: [
            structureHistoryEntry(id: "run-1"),
        ]
    )
    let duplicate = DeliveryHistorySnapshot(
        repository: item.repository,
        entries: [
            structureHistoryEntry(id: "run-1"),
            structureHistoryEntry(id: "run-1"),
        ]
    )
    let valid = DeliveryHistorySnapshot(
        repository: item.repository,
        entries: [
            structureHistoryEntry(id: "run-1"),
            structureHistoryEntry(id: "run-2"),
        ]
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            mismatch,
            selectedItem: item
        )
    )
    #expect(
        !ActivityDetailStructurePolicy.allows(
            duplicate,
            selectedItem: item
        )
    )
    #expect(
        ActivityDetailStructurePolicy.allows(
            valid,
            selectedItem: item
        )
    )
}

@Test(arguments: [
    "",
    "unsafe\nidentifier",
    String(repeating: "a", count: 257),
])
func historyStructureRejectsInvalidEntryIdentity(
    id: String
) {
    let item = structureItem()
    let history = DeliveryHistorySnapshot(
        repository: item.repository,
        entries: [structureHistoryEntry(id: id)]
    )

    #expect(
        !ActivityDetailStructurePolicy.allows(
            history,
            selectedItem: item
        )
    )
}

private func structureItem() -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
        repository: "snow/app",
        context: "CI",
        detail: "Succeeded",
        state: .success,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func structureDetail(
    item: ActivityItem,
    rows: [ActivityDetailRow]
) -> ActivityDetailSnapshot {
    ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: item.context,
        summary: "Jobs",
        state: item.state,
        rows: rows
    )
}

private func structureRow(
    id: String
) -> ActivityDetailRow {
    ActivityDetailRow(
        id: id,
        title: "Job",
        state: .success
    )
}

private func structureHistoryEntry(
    id: String
) -> DeliveryHistoryEntry {
    DeliveryHistoryEntry(
        id: id,
        title: "Run",
        state: .success,
        occurredAt: Date(timeIntervalSince1970: 100)
    )
}
