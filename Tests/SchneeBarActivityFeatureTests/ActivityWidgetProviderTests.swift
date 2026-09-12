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
    #expect(snapshot.content(for: .normal).text == "CI ✕1")
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
    #expect(snapshot.content(for: .compact).text == "●1")
}
