@testable import SchneeBar
import Testing

@Test(arguments: [
    (
        ExternalWidgetStartupHealth.notAttempted,
        ExternalWidgetStartupHealthPresentation(
            title: "Not checked",
            detail: "External widgets are checked once at app startup.",
            systemImage: "clock"
        )
    ),
    (
        ExternalWidgetStartupHealth.loading,
        ExternalWidgetStartupHealthPresentation(
            title: "Loading",
            detail: "Validating external widget documents.",
            systemImage: "hourglass"
        )
    ),
    (
        ExternalWidgetStartupHealth.loaded(widgetCount: 0),
        ExternalWidgetStartupHealthPresentation(
            title: "Loaded",
            detail: "No external widgets were loaded.",
            systemImage: "checkmark.circle"
        )
    ),
    (
        ExternalWidgetStartupHealth.loaded(widgetCount: 1),
        ExternalWidgetStartupHealthPresentation(
            title: "Loaded",
            detail: "1 external widget loaded.",
            systemImage: "checkmark.circle"
        )
    ),
    (
        ExternalWidgetStartupHealth.loaded(widgetCount: 3),
        ExternalWidgetStartupHealthPresentation(
            title: "Loaded",
            detail: "3 external widgets loaded.",
            systemImage: "checkmark.circle"
        )
    ),
])
func startupHealthPresentationUsesOnlyCoarseState(
    health: ExternalWidgetStartupHealth,
    expected: ExternalWidgetStartupHealthPresentation
) {
    #expect(health.presentation == expected)
}

@Test(arguments: [
    (
        ExternalWidgetStartupFailureReason.unsafeStorage,
        "External widget storage did not pass safety checks."
    ),
    (
        ExternalWidgetStartupFailureReason.resourceLimit,
        "External widget storage exceeded a safety limit."
    ),
    (
        ExternalWidgetStartupFailureReason.invalidDocuments,
        "One or more external widget documents are invalid."
    ),
    (
        ExternalWidgetStartupFailureReason.unreadableStorage,
        "External widget storage could not be read."
    ),
    (
        ExternalWidgetStartupFailureReason.registrationConflict,
        "External widgets could not be registered safely."
    ),
    (
        ExternalWidgetStartupFailureReason.unknown,
        "External widgets are unavailable."
    ),
])
func unavailablePresentationDoesNotExposeConcreteErrors(
    reason: ExternalWidgetStartupFailureReason,
    expectedDetail: String
) {
    #expect(
        ExternalWidgetStartupHealth.unavailable(reason).presentation
            == ExternalWidgetStartupHealthPresentation(
                title: "Unavailable",
                detail: expectedDetail,
                systemImage: "exclamationmark.triangle"
            )
    )
}
