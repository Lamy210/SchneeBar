import SchneeBarCore

enum ExternalWidgetStartupFailureReason:
    Equatable,
    Sendable
{
    case unsafeStorage
    case resourceLimit
    case invalidDocuments
    case unreadableStorage
    case registrationConflict
    case unknown
}

enum ExternalWidgetStartupRegistrationResult:
    Equatable,
    Sendable
{
    case loaded(widgetCount: Int)
    case unavailable(ExternalWidgetStartupFailureReason)
}

enum ExternalWidgetStartupHealth:
    Equatable,
    Sendable
{
    case notAttempted
    case loading
    case loaded(widgetCount: Int)
    case unavailable(ExternalWidgetStartupFailureReason)
}

enum ExternalWidgetStartupHealthPolicy {
    static func terminalHealth(
        for result: ExternalWidgetStartupRegistrationResult,
        generation: WidgetRuntimeLifecycle.Generation,
        lifecycle: WidgetRuntimeLifecycle
    ) -> ExternalWidgetStartupHealth? {
        guard lifecycle.isCurrent(generation) else {
            return nil
        }

        switch result {
        case let .loaded(widgetCount):
            return .loaded(widgetCount: widgetCount)
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    static func healthAfterSleep(
        current: ExternalWidgetStartupHealth,
        startupFinished: Bool
    ) -> ExternalWidgetStartupHealth {
        startupFinished ? current : .notAttempted
    }
}


struct ExternalWidgetStartupHealthPresentation:
    Equatable,
    Sendable
{
    let title: String
    let detail: String
    let systemImage: String
}

extension ExternalWidgetStartupHealth {
    var presentation: ExternalWidgetStartupHealthPresentation {
        switch self {
        case .notAttempted:
            return ExternalWidgetStartupHealthPresentation(
                title: "Not checked",
                detail: "External widgets are checked once at app startup.",
                systemImage: "clock"
            )

        case .loading:
            return ExternalWidgetStartupHealthPresentation(
                title: "Loading",
                detail: "Validating external widget documents.",
                systemImage: "hourglass"
            )

        case let .loaded(widgetCount):
            let detail: String
            switch widgetCount {
            case 0:
                detail = "No external widgets were loaded."
            case 1:
                detail = "1 external widget loaded."
            default:
                detail = "\(widgetCount) external widgets loaded."
            }
            return ExternalWidgetStartupHealthPresentation(
                title: "Loaded",
                detail: detail,
                systemImage: "checkmark.circle"
            )

        case let .unavailable(reason):
            return ExternalWidgetStartupHealthPresentation(
                title: "Unavailable",
                detail: reason.presentationDetail,
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}

private extension ExternalWidgetStartupFailureReason {
    var presentationDetail: String {
        switch self {
        case .unsafeStorage:
            return "External widget storage did not pass safety checks."
        case .resourceLimit:
            return "External widget storage exceeded a safety limit."
        case .invalidDocuments:
            return "One or more external widget documents are invalid."
        case .unreadableStorage:
            return "External widget storage could not be read."
        case .registrationConflict:
            return "External widgets could not be registered safely."
        case .unknown:
            return "External widgets are unavailable."
        }
    }
}
