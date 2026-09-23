import Foundation
import SchneeBarCore

public enum ActivityDetailFixtureScenario: String, CaseIterable, Identifiable {
    case failed
    case matrixSuccess = "matrix-success"
    case matrixFailure = "matrix-failure"
    case deliveryExact = "delivery-exact"
    case deliveryDefaultBranch = "delivery-default-branch"
    case deliveryNonDefaultBranch = "delivery-non-default-branch"
    case deliveryEvidenceUnavailable = "delivery-evidence-unavailable"
    case deliveryTemporarilyUnavailable = "delivery-temporarily-unavailable"
    case deliveryMatrixFailure = "delivery-matrix-failure"
    case deploymentProductionSuccess = "deployment-production-success"
    case deploymentStagingRunning = "deployment-staging-running"
    case deploymentNone = "deployment-none"
    case deploymentCapabilityUnavailable = "deployment-capability-unavailable"
    case deploymentBoundedMultiple = "deployment-bounded-multiple"
    case environmentProductionProtected = "environment-production-protected"
    case environmentStagingProtected = "environment-staging-protected"
    case environmentCapabilityUnavailable = "environment-capability-unavailable"
    case environmentRequestFailure = "environment-request-failure"
    case environmentCatalogTruncatedMatched = "environment-catalog-truncated-matched"
    case environmentPartialMatches = "environment-partial-matches"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .failed: "Failed jobs"
        case .matrixSuccess: "Matrix success"
        case .matrixFailure: "Matrix failure"
        case .deliveryExact: "Delivery exact"
        case .deliveryDefaultBranch: "Delivery default branch"
        case .deliveryNonDefaultBranch: "Delivery non-default branch"
        case .deliveryEvidenceUnavailable: "Delivery evidence unavailable"
        case .deliveryTemporarilyUnavailable: "Delivery temporarily unavailable"
        case .deliveryMatrixFailure: "Delivery + matrix failure"
        case .deploymentProductionSuccess: "Deployment production success"
        case .deploymentStagingRunning: "Deployment staging running"
        case .deploymentNone: "Deployment none"
        case .deploymentCapabilityUnavailable: "Deployment capability unavailable"
        case .deploymentBoundedMultiple: "Deployment bounded multiple"
        case .environmentProductionProtected: "Environment production protected"
        case .environmentStagingProtected: "Environment staging protected"
        case .environmentCapabilityUnavailable: "Environment capability unavailable"
        case .environmentRequestFailure: "Environment request failure"
        case .environmentCatalogTruncatedMatched: "Environment truncated matched"
        case .environmentPartialMatches: "Environment partial matches"
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
        case .deliveryExact: ActivityDetailFixture.deliveryExact
        case .deliveryDefaultBranch: ActivityDetailFixture.deliveryDefaultBranch
        case .deliveryNonDefaultBranch: ActivityDetailFixture.deliveryNonDefaultBranch
        case .deliveryEvidenceUnavailable: ActivityDetailFixture.deliveryEvidenceUnavailable
        case .deliveryTemporarilyUnavailable: ActivityDetailFixture.deliveryTemporarilyUnavailable
        case .deliveryMatrixFailure: ActivityDetailFixture.deliveryMatrixFailure
        case .deploymentProductionSuccess: ActivityDetailFixture.deploymentProductionSuccess
        case .deploymentStagingRunning: ActivityDetailFixture.deploymentStagingRunning
        case .deploymentNone: ActivityDetailFixture.deploymentNone
        case .deploymentCapabilityUnavailable: ActivityDetailFixture.deploymentCapabilityUnavailable
        case .deploymentBoundedMultiple: ActivityDetailFixture.deploymentBoundedMultiple
        case .environmentProductionProtected: ActivityDetailFixture.environmentProductionProtected
        case .environmentStagingProtected: ActivityDetailFixture.environmentStagingProtected
        case .environmentCapabilityUnavailable: ActivityDetailFixture.environmentCapabilityUnavailable
        case .environmentRequestFailure: ActivityDetailFixture.environmentRequestFailure
        case .environmentCatalogTruncatedMatched: ActivityDetailFixture.environmentCatalogTruncatedMatched
        case .environmentPartialMatches: ActivityDetailFixture.environmentPartialMatches
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
        actions: [.rerunWorkflow],
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

    public static let exactDeliveryEvidence: [DeliveryTimelineEvidenceItem] = [
        DeliveryTimelineEvidenceItem(
            id: "workflow-pull-request",
            title: "Workflow pull request",
            detail: "Selected workflow is attached to PR #49",
            state: .confirmed
        ),
        DeliveryTimelineEvidenceItem(
            id: "merged-pull-request",
            title: "Merged pull request",
            detail: "PR #49 is merged",
            state: .confirmed
        ),
        DeliveryTimelineEvidenceItem(
            id: "final-pull-request-revision",
            title: "Final pull request revision",
            detail: "Selected workflow represents the merged pull request's final revision",
            state: .confirmed
        ),
        DeliveryTimelineEvidenceItem(
            id: "target-branch-execution",
            title: "Target branch execution",
            detail: "Workflow execution found on target branch main",
            state: .confirmed
        ),
        DeliveryTimelineEvidenceItem(
            id: "commit-association",
            title: "Commit association",
            detail: "Target-branch execution is associated with PR #49",
            state: .confirmed
        ),
    ]

    public static let exactDeliveryTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: [
            DeliveryTimelineEvent(
                id: "github-delivery-pr:49",
                kind: .pullRequest,
                title: "PR #49 workflow",
                detail: "feat/delivery-timeline-first-slice → main",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_000)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-merge:49",
                kind: .merge,
                title: "Merged",
                detail: "into main",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/pull/49"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_120)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-execution:601",
                kind: .execution,
                title: "Base branch · CI",
                detail: "Succeeded",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/601"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_180)
            ),
        ],
        evidence: exactDeliveryEvidence
    )

    public static let deliveryExact = ActivityDetailSnapshot(
        id: "github-actions:42:501:delivery-exact",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: exactDeliveryTimeline,
        rows: matrixSuccess.rows
    )

    public static let defaultBranchDeliveryTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: [
            DeliveryTimelineEvent(
                id: "github-delivery-pr:49",
                kind: .pullRequest,
                title: "PR #49 workflow",
                detail: "feat/delivery-timeline-first-slice → main",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_000)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-merge:49",
                kind: .merge,
                title: "Merged",
                detail: "into main",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/pull/49"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_120)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-execution:601",
                kind: .execution,
                title: "Default branch · CI",
                detail: "Succeeded",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/601"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_180)
            ),
        ]
    )

    public static let nonDefaultBranchDeliveryTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: [
            DeliveryTimelineEvent(
                id: "github-delivery-pr:49",
                kind: .pullRequest,
                title: "PR #49 workflow",
                detail: "feat/release-fix → release/1.x",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/501"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_000)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-merge:49",
                kind: .merge,
                title: "Merged",
                detail: "into release/1.x",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/pull/49"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_120)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-execution:601",
                kind: .execution,
                title: "Base branch · CI",
                detail: "Succeeded",
                state: .success,
                destinationURL: URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/601"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_180)
            ),
        ]
    )

    public static let deliveryDefaultBranch = ActivityDetailSnapshot(
        id: "github-actions:42:501:delivery-default-branch",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: defaultBranchDeliveryTimeline,
        rows: matrixSuccess.rows
    )

    public static let deliveryNonDefaultBranch = ActivityDetailSnapshot(
        id: "github-actions:42:501:delivery-non-default-branch",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: nonDefaultBranchDeliveryTimeline,
        rows: matrixSuccess.rows
    )

    public static let deliveryEvidenceUnavailable = ActivityDetailSnapshot(
        id: "github-actions:42:501:delivery-evidence-unavailable",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .evidenceUnavailable,
            confidence: .unknown,
            events: [],
            evidence: [
                DeliveryTimelineEvidenceItem(
                    id: "commit-association",
                    title: "Commit association",
                    detail: "No target-branch execution commit was associated with the pull request",
                    state: .missing
                ),
            ]
        ),
        rows: matrixSuccess.rows
    )

    public static let deliveryTemporarilyUnavailable = ActivityDetailSnapshot(
        id: "github-actions:42:501:delivery-temporarily-unavailable",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .temporarilyUnavailable,
            confidence: .unknown,
            events: [],
            evidence: [
                DeliveryTimelineEvidenceItem(
                    id: "delivery-evidence-load",
                    title: "Delivery evidence",
                    detail: "GitHub evidence could not be loaded right now",
                    state: .unavailable
                ),
            ]
        ),
        rows: matrixSuccess.rows
    )

    public static let deliveryMatrixFailure = ActivityDetailSnapshot(
        id: "github-actions:42:501:delivery-matrix-failure",
        repository: item.repository,
        title: item.context,
        summary: matrixFailure.summary,
        state: .failed,
        destinationURL: item.destinationURL,
        deliveryTimeline: exactDeliveryTimeline,
        rows: matrixFailure.rows
    )


    public static let productionDeploymentTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:901",
                kind: .deployment,
                title: "Deployment · production",
                detail: "Succeeded · Production",
                state: .success,
                destinationURL: URL(string: "https://deploy.example.test/production"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_240)
            ),
        ],
        evidence: exactDeliveryEvidence + [
            DeliveryTimelineEvidenceItem(
                id: "deployment-commit-match",
                title: "Deployment commit match",
                detail: "1 deployment matched the correlated execution commit",
                state: .confirmed
            ),
        ]
    )

    public static let stagingRunningDeploymentTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:902",
                kind: .deployment,
                title: "Deployment · staging",
                detail: "Running",
                state: .running,
                destinationURL: URL(string: "https://deploy.example.test/staging"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_260)
            ),
        ]
    )

    public static let boundedMultipleDeploymentTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:903",
                kind: .deployment,
                title: "Deployment · production",
                detail: "Succeeded · Production",
                state: .success,
                destinationURL: URL(string: "https://deploy.example.test/production"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_300)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:904",
                kind: .deployment,
                title: "Deployment · staging",
                detail: "Running",
                state: .running,
                destinationURL: URL(string: "https://deploy.example.test/staging"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_290)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:905",
                kind: .deployment,
                title: "Deployment · preview",
                detail: "Pending · Transient",
                state: .waiting,
                destinationURL: URL(string: "https://deploy.example.test/preview"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_280)
            ),
        ]
    )

    public static let deploymentProductionSuccess = ActivityDetailSnapshot(
        id: "github-actions:42:501:deployment-production-success",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: productionDeploymentTimeline,
        rows: matrixSuccess.rows
    )

    public static let deploymentStagingRunning = ActivityDetailSnapshot(
        id: "github-actions:42:501:deployment-staging-running",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: stagingRunningDeploymentTimeline,
        rows: matrixSuccess.rows
    )

    public static let deploymentNone = ActivityDetailSnapshot(
        id: "github-actions:42:501:deployment-none",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: exactDeliveryTimeline,
        rows: matrixSuccess.rows
    )

    public static let deploymentCapabilityUnavailable = ActivityDetailSnapshot(
        id: "github-actions:42:501:deployment-capability-unavailable",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: exactDeliveryTimeline,
        rows: matrixSuccess.rows
    )

    public static let deploymentBoundedMultiple = ActivityDetailSnapshot(
        id: "github-actions:42:501:deployment-bounded-multiple",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: boundedMultipleDeploymentTimeline,
        rows: matrixSuccess.rows
    )


    public static let environmentProductionProtectedTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:1001",
                kind: .deployment,
                title: "Deployment · production",
                detail: "Succeeded · Production · 2 reviewers · 30m wait · No self-review · Custom branches",
                state: .success,
                destinationURL: URL(string: "https://deploy.example.test/production"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_300)
            ),
        ]
    )

    public static let environmentStagingProtectedTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:1002",
                kind: .deployment,
                title: "Deployment · staging",
                detail: "Running · Protected branches",
                state: .running,
                destinationURL: URL(string: "https://deploy.example.test/staging"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_310)
            ),
        ]
    )

    public static let environmentTruncatedMatchedTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:1003",
                kind: .deployment,
                title: "Deployment · production",
                detail: "Succeeded · Production · 1 reviewer · 1h wait",
                state: .success,
                destinationURL: URL(string: "https://deploy.example.test/production"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_320)
            ),
        ]
    )

    public static let environmentPartialMatchesTimeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: exactDeliveryTimeline.events + [
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:1004",
                kind: .deployment,
                title: "Deployment · production",
                detail: "Succeeded · Production · 2 reviewers · Custom branches",
                state: .success,
                destinationURL: URL(string: "https://deploy.example.test/production"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_330)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:1005",
                kind: .deployment,
                title: "Deployment · staging",
                detail: "Running",
                state: .running,
                destinationURL: URL(string: "https://deploy.example.test/staging"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_325)
            ),
            DeliveryTimelineEvent(
                id: "github-delivery-deployment:1006",
                kind: .deployment,
                title: "Deployment · preview",
                detail: "Pending · Transient · 15m wait",
                state: .waiting,
                destinationURL: URL(string: "https://deploy.example.test/preview"),
                occurredAt: Date(timeIntervalSince1970: 1_789_710_315)
            ),
        ]
    )

    public static let environmentProductionProtected = ActivityDetailSnapshot(
        id: "github-actions:42:501:environment-production-protected",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: environmentProductionProtectedTimeline,
        rows: matrixSuccess.rows
    )

    public static let environmentStagingProtected = ActivityDetailSnapshot(
        id: "github-actions:42:501:environment-staging-protected",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: environmentStagingProtectedTimeline,
        rows: matrixSuccess.rows
    )

    public static let environmentCapabilityUnavailable = ActivityDetailSnapshot(
        id: "github-actions:42:501:environment-capability-unavailable",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: productionDeploymentTimeline,
        rows: matrixSuccess.rows
    )

    public static let environmentRequestFailure = ActivityDetailSnapshot(
        id: "github-actions:42:501:environment-request-failure",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: productionDeploymentTimeline,
        rows: matrixSuccess.rows
    )

    public static let environmentCatalogTruncatedMatched = ActivityDetailSnapshot(
        id: "github-actions:42:501:environment-catalog-truncated-matched",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: environmentTruncatedMatchedTimeline,
        rows: matrixSuccess.rows
    )

    public static let environmentPartialMatches = ActivityDetailSnapshot(
        id: "github-actions:42:501:environment-partial-matches",
        repository: item.repository,
        title: item.context,
        summary: matrixSuccess.summary,
        state: .success,
        destinationURL: item.destinationURL,
        deliveryTimeline: environmentPartialMatchesTimeline,
        rows: matrixSuccess.rows
    )

}
