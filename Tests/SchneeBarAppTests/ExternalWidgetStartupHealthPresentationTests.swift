import Testing
@testable import SchneeBar

@Test(arguments: [
    (
        ExternalWidgetStartupHealth.notAttempted,
        "Not loaded",
        "External widgets have not been checked during this app session."
    ),
    (
        ExternalWidgetStartupHealth.loading,
        "Loading",
        "SchneeBar is validating external widget documents."
    ),
    (
        ExternalWidgetStartupHealth.loaded(widgetCount: 0),
        "Loaded",
        "No external widgets were found at startup."
    ),
    (
        ExternalWidgetStartupHealth.loaded(widgetCount: 1),
        "Loaded",
        "1 external widget was loaded at startup."
    ),
    (
        ExternalWidgetStartupHealth.loaded(widgetCount: 3),
        "Loaded",
        "3 external widgets were loaded at startup."
    ),
])
func externalWidgetHealthPresentationUsesSanitizedCopy(
    health: ExternalWidgetStartupHealth,
    expectedStatus: String,
    expectedDetail: String
) {
    let presentation = ExternalWidgetStartupHealthPresentation.make(
        from: health
    )

    #expect(presentation.status == expectedStatus)
    #expect(presentation.detail == expectedDetail)
}

@Test(arguments: [
    (
        ExternalWidgetStartupFailureReason.unsafeStorage,
        "External widget storage did not pass safety checks."
    ),
    (
        ExternalWidgetStartupFailureReason.resourceLimit,
        "External widget files exceed supported startup limits."
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
        "External widgets conflict with an existing widget provider."
    ),
    (
        ExternalWidgetStartupFailureReason.unknown,
        "External widgets could not be loaded."
    ),
])
func unavailableExternalWidgetHealthNeverUsesRawProviderEvidence(
    reason: ExternalWidgetStartupFailureReason,
    expectedDetail: String
) {
    let presentation = ExternalWidgetStartupHealthPresentation.make(
        from: .unavailable(reason)
    )

    #expect(presentation.status == "Unavailable")
    #expect(presentation.detail == expectedDetail)
    #expect(!presentation.detail.contains("/"))
    #expect(!presentation.detail.contains(".json"))
    #expect(!presentation.detail.contains("external."))
}
