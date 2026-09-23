import Foundation
@testable import SchneeBarActivityFeature
import SchneeBarCore
import Testing

@Test
func activityDetailRowInteractionPrefersDisclosureForChildren() {
    let child = ActivityDetailRow(
        id: "child",
        title: "macos",
        detail: "Failed",
        state: .failed,
        destinationURL: URL(string: "https://github.com/octocat/project/actions/runs/1/job/11")
    )
    let row = ActivityDetailRow(
        id: "group",
        title: "Test",
        detail: "2 variants · 1 failed",
        state: .failed,
        destinationURL: URL(string: "https://github.com/octocat/project/actions/runs/1"),
        children: [child]
    )

    #expect(activityDetailRowInteraction(row) == .disclosure)
}

@Test
func activityDetailRowInteractionUsesLinkForChildlessDestination() throws {
    let destination = try #require(
        URL(string: "https://github.com/octocat/project/actions/runs/1/job/11")
    )
    let row = ActivityDetailRow(
        id: "11",
        title: "Build",
        detail: "Succeeded",
        state: .success,
        destinationURL: destination
    )

    #expect(activityDetailRowInteraction(row) == .link(destination))
}

@Test
func activityDetailRowInteractionUsesNoneForPlainRow() {
    let row = ActivityDetailRow(
        id: "plain",
        title: "Build",
        detail: nil,
        state: .neutral
    )

    #expect(activityDetailRowInteraction(row) == .none)
}

@Test
func deliveryTimelineConfidenceLabelsRemainExact() {
    #expect(deliveryTimelineConfidenceLabel(.exact) == "Exact correlation")
    #expect(deliveryTimelineConfidenceLabel(.high) == "High-confidence correlation")
    #expect(deliveryTimelineConfidenceLabel(.medium) == "Medium-confidence correlation")
    #expect(deliveryTimelineConfidenceLabel(.unknown) == "Correlation unavailable")
}

@Test
func deliveryTimelineUnavailableCopyDistinguishesEvidenceFromTechnicalFailure() {
    #expect(deliveryTimelineUnavailableMessage(for: .correlated) == nil)
    #expect(
        deliveryTimelineUnavailableMessage(for: .evidenceUnavailable)
            == "Correlation evidence unavailable"
    )
    #expect(
        deliveryTimelineUnavailableMessage(for: .temporarilyUnavailable)
            == "Delivery timeline temporarily unavailable"
    )
}

@Test
func deliveryTimelineEventUsesExistingActivityDetailStateIconLanguage() {
    let success = DeliveryTimelineEvent(
        id: "success",
        kind: .execution,
        title: "CI",
        state: .success
    )
    let failed = DeliveryTimelineEvent(
        id: "failed",
        kind: .execution,
        title: "CI",
        state: .failed
    )
    let waiting = DeliveryTimelineEvent(
        id: "waiting",
        kind: .execution,
        title: "CI",
        state: .waiting
    )

    #expect(deliveryTimelineEventIconName(success) == "checkmark.circle.fill")
    #expect(deliveryTimelineEventIconName(failed) == "xmark.octagon.fill")
    #expect(deliveryTimelineEventIconName(waiting) == "clock.fill")
}


@Test
func deliveryHistoryActionRequiresLoadedDetailAndHandler() {
    let detail = ActivityDetailSnapshot(
        id: "run",
        repository: "snow/repo",
        title: "CI",
        summary: "1 job",
        state: .success,
        rows: []
    )

    #expect(deliveryHistoryActionIsAvailable(detail: detail, hasHandler: true))
    #expect(!deliveryHistoryActionIsAvailable(detail: nil, hasHandler: true))
    #expect(!deliveryHistoryActionIsAvailable(detail: detail, hasHandler: false))
}

@Test
func deliveryHistoryEntriesUseActivityDetailStateIconLanguage() {
    let entry = DeliveryHistoryEntry(
        id: "run",
        title: "CI",
        detail: "Succeeded · Default branch · Run #1",
        state: .success,
        occurredAt: Date(timeIntervalSince1970: 1)
    )

    #expect(deliveryHistoryEntryIconName(entry) == "checkmark.circle.fill")
}


@Test
func deliveryTimelineEvidenceDisclosureLabelsExplainStatus() {
    #expect(
        deliveryTimelineEvidenceDisclosureLabel(for: .correlated)
            == "Why this correlation"
    )
    #expect(
        deliveryTimelineEvidenceDisclosureLabel(for: .evidenceUnavailable)
            == "Why correlation is unavailable"
    )
    #expect(
        deliveryTimelineEvidenceDisclosureLabel(for: .temporarilyUnavailable)
            == "Why evidence could not be checked"
    )
}

@Test
func deliveryTimelineEvidenceUsesDistinctStateIcons() {
    #expect(
        deliveryTimelineEvidenceIconName(.confirmed)
            == "checkmark.circle.fill"
    )
    #expect(
        deliveryTimelineEvidenceIconName(.missing)
            == "questionmark.circle.fill"
    )
    #expect(
        deliveryTimelineEvidenceIconName(.unavailable)
            == "exclamationmark.triangle.fill"
    )
}

@Test
func deliveryTimelineEvidenceDisclosureRequiresEvidence() {
    let empty = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: []
    )
    let explained = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: [],
        evidence: [
            DeliveryTimelineEvidenceItem(
                id: "workflow-pr",
                title: "Workflow pull request",
                state: .confirmed
            ),
        ]
    )

    #expect(!deliveryTimelineShouldShowEvidence(empty))
    #expect(deliveryTimelineShouldShowEvidence(explained))
}


@Test
func workflowDetailActionLabelsRemainExplicit() {
    #expect(activityDetailActionLabel(.rerunWorkflow) == "Re-run workflow")
    #expect(activityDetailActionLabel(.cancelWorkflow) == "Cancel workflow")
}

@Test
func workflowDetailActionConfirmationCopyNamesMutation() {
    #expect(
        activityDetailActionConfirmationTitle(.rerunWorkflow)
            == "Re-run this workflow?"
    )
    #expect(
        activityDetailActionConfirmationTitle(.cancelWorkflow)
            == "Cancel this workflow?"
    )
}

@Test
func workflowDetailActionsRequireLoadedActionHandlerAndIdleState() {
    let detail = ActivityDetailSnapshot(
        id: "run",
        repository: "snow/app",
        title: "CI",
        summary: "Failed",
        state: .failed,
        actions: [.rerunWorkflow],
        rows: []
    )

    #expect(
        activityDetailActionsAreAvailable(
            detail: detail,
            hasHandler: true,
            isRunning: false
        )
    )
    #expect(
        !activityDetailActionsAreAvailable(
            detail: detail,
            hasHandler: false,
            isRunning: false
        )
    )
    #expect(
        !activityDetailActionsAreAvailable(
            detail: detail,
            hasHandler: true,
            isRunning: true
        )
    )
}
