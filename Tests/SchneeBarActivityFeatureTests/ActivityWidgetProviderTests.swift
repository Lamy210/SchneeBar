import SchneeBarActivityFeature
import SchneeBarCore
import Testing

@Test
func failedActivityPromotesWidgetToCritical() async throws {
    let provider = ActivityWidgetProvider {
        [
            ActivityItem(
                id: "failed",
                repository: "SchneeBar",
                context: "main",
                detail: "Tests failed",
                state: .failed
            ),
        ]
    }

    let snapshot = try await provider.snapshot()

    #expect(snapshot.severity == .critical)
    #expect(snapshot.priority == .critical)
    #expect(snapshot.isVisible)
    #expect(snapshot.content(for: .normal).text == "Alert 1")
    #expect(snapshot.content(for: .compact).text == "✕1")
}

@Test
func reviewRequestPromotesWidgetToAttention() async throws {
    let provider = ActivityWidgetProvider {
        [
            ActivityItem(
                id: "review",
                repository: "SchneeBar",
                context: "PR #7",
                detail: "Review requested",
                state: .waiting,
                kind: .reviewRequest,
                attention: .actionRequired
            ),
        ]
    }

    let snapshot = try await provider.snapshot()

    #expect(snapshot.severity == .attention)
    #expect(snapshot.priority == .attention)
    #expect(snapshot.isVisible)
    #expect(snapshot.content(for: .normal).text == "Action 1")
    #expect(snapshot.content(for: .compact).text == "!1")
}

@Test
func failedCheckKeepsWidgetCriticalWhenReviewAlsoExists() async throws {
    let provider = ActivityWidgetProvider {
        [
            ActivityItem(
                id: "review",
                repository: "SchneeBar",
                context: "PR #7",
                detail: "Review requested",
                state: .waiting,
                kind: .reviewRequest,
                attention: .actionRequired
            ),
            ActivityItem(
                id: "check",
                repository: "SchneeBar",
                context: "Codecov",
                detail: "Failed",
                state: .failed,
                kind: .checkRun,
                attention: .needsAttention
            ),
        ]
    }

    let snapshot = try await provider.snapshot()

    #expect(snapshot.severity == .critical)
    #expect(snapshot.priority == .critical)
    #expect(snapshot.content(for: .normal).text == "Action 1")
    #expect(snapshot.content(for: .compact).text == "!1")
}

@Test
func nominalActivityIsHiddenBySmartVisibility() async throws {
    let provider = ActivityWidgetProvider {
        [
            ActivityItem(
                id: "healthy",
                repository: "SchneeBar",
                context: "main",
                detail: "CI passed",
                state: .success
            ),
        ]
    }

    let snapshot = try await provider.snapshot()

    #expect(snapshot.severity == .nominal)
    #expect(!snapshot.isVisible)
    #expect(snapshot.descriptor.refreshPolicy.interval(for: .nominal) == 180)
    #expect(snapshot.content(for: .normal).text == "Clear")
}

@Test
func runningActivityUsesFastRefreshAndAttentionPriority() async throws {
    let provider = ActivityWidgetProvider {
        [
            ActivityItem(
                id: "running",
                repository: "SchneeBar",
                context: "PR #1",
                detail: "4 / 6 jobs",
                state: .running
            ),
        ]
    }

    let snapshot = try await provider.snapshot()

    #expect(snapshot.severity == .active)
    #expect(snapshot.priority == .attention)
    #expect(snapshot.descriptor.refreshPolicy.interval(for: snapshot.severity) == 20)
    #expect(snapshot.content(for: .normal).text == "Running 1")
    #expect(snapshot.content(for: .compact).text == "●1")
}
