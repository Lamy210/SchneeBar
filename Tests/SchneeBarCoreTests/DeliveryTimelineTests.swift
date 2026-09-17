import Foundation
import SchneeBarCore
import Testing

@Test
func deliveryTimelinePreservesDeliveryOrderAndConfidence() {
    let pullRequest = DeliveryTimelineEvent(
        id: "pr-47",
        kind: .pullRequest,
        title: "PR #47 workflow",
        detail: "feature/delivery -> main",
        state: .success,
        destinationURL: URL(string: "https://github.com/snow/repo/pull/47"),
        occurredAt: Date(timeIntervalSince1970: 100)
    )
    let merge = DeliveryTimelineEvent(
        id: "merge-47",
        kind: .merge,
        title: "Merged",
        detail: "into main",
        state: .success,
        destinationURL: URL(string: "https://github.com/snow/repo/pull/47"),
        occurredAt: Date(timeIntervalSince1970: 200)
    )
    let execution = DeliveryTimelineEvent(
        id: "run-900",
        kind: .execution,
        title: "Base branch · CI",
        detail: "Succeeded",
        state: .success,
        destinationURL: URL(string: "https://github.com/snow/repo/actions/runs/900"),
        occurredAt: Date(timeIntervalSince1970: 300)
    )

    let timeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: [pullRequest, merge, execution]
    )

    #expect(timeline.status == .correlated)
    #expect(timeline.confidence == .exact)
    #expect(timeline.events.map(\.kind) == [.pullRequest, .merge, .execution])
}

@Test
func deliveryTimelineUnavailableStatesRemainDistinct() {
    let missingEvidence = DeliveryTimelineSnapshot(
        status: .evidenceUnavailable,
        confidence: .unknown,
        events: []
    )
    let technicalFailure = DeliveryTimelineSnapshot(
        status: .temporarilyUnavailable,
        confidence: .unknown,
        events: []
    )

    #expect(missingEvidence.status != technicalFailure.status)
    #expect(missingEvidence.confidence == .unknown)
    #expect(technicalFailure.confidence == .unknown)
}

@Test
func activityDetailDefaultsDeliveryTimelineToNil() {
    let detail = ActivityDetailSnapshot(
        id: "workflow",
        repository: "snow/repo",
        title: "CI",
        summary: "1 job",
        state: .running,
        rows: []
    )

    #expect(detail.deliveryTimeline == nil)
}
