struct ExternalWidgetStartupHealthPresentation:
    Equatable,
    Sendable
{
    let status: String
    let detail: String
    let systemImage: String

    static func make(
        from health: ExternalWidgetStartupHealth
    ) -> Self {
        switch health {
        case .notAttempted:
            return Self(
                status: "Not loaded",
                detail: "External widgets have not been checked during this app session.",
                systemImage: "circle.dashed"
            )

        case .loading:
            return Self(
                status: "Loading",
                detail: "SchneeBar is validating external widget documents.",
                systemImage: "hourglass"
            )

        case let .loaded(widgetCount):
            let detail: String
            if widgetCount == 0 {
                detail = "No external widgets were found at startup."
            } else if widgetCount == 1 {
                detail = "1 external widget was loaded at startup."
            } else {
                detail = "\(widgetCount) external widgets were loaded at startup."
            }
            return Self(
                status: "Loaded",
                detail: detail,
                systemImage: "checkmark.circle"
            )

        case let .unavailable(reason):
            return Self(
                status: "Unavailable",
                detail: unavailableDetail(for: reason),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private static func unavailableDetail(
        for reason: ExternalWidgetStartupFailureReason
    ) -> String {
        switch reason {
        case .unsafeStorage:
            return "External widget storage did not pass safety checks."
        case .resourceLimit:
            return "External widget files exceed supported startup limits."
        case .invalidDocuments:
            return "One or more external widget documents are invalid."
        case .unreadableStorage:
            return "External widget storage could not be read."
        case .registrationConflict:
            return "External widgets conflict with an existing widget provider."
        case .unknown:
            return "External widgets could not be loaded."
        }
    }
}
