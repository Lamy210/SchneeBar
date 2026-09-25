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


struct ExternalWidgetStartupHealthPresentation: Equatable, Sendable {
    let status: String
    let detail: String
    let systemImage: String
}

extension ExternalWidgetStartupHealth {
    var settingsPresentation: ExternalWidgetStartupHealthPresentation {
        switch self {
        case .notAttempted:
            return .init(
                status: "Not loaded",
                detail: "External widgets have not been loaded in this app session.",
                systemImage: "circle.dashed"
            )

        case .loading:
            return .init(
                status: "Loading",
                detail: "External widget documents are being validated before registration.",
                systemImage: "hourglass"
            )

        case let .loaded(widgetCount):
            if widgetCount == 0 {
                return .init(
                    status: "No external widgets",
                    detail: "Startup validation completed without registering external widgets.",
                    systemImage: "checkmark.circle"
                )
            }
            return .init(
                status: "Loaded",
                detail: "\(widgetCount) external widget\(widgetCount == 1 ? "" : "s") registered. Saved preferences are preserved; newly discovered external widgets default to disabled.",
                systemImage: "checkmark.circle"
            )

        case let .unavailable(reason):
            return .init(
                status: "Unavailable",
                detail: reason.settingsDetail,
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}

private extension ExternalWidgetStartupFailureReason {
    var settingsDetail: String {
        switch self {
        case .unsafeStorage:
            return "External widget storage did not pass safety checks."
        case .resourceLimit:
            return "External widget storage exceeded configured safety limits."
        case .invalidDocuments:
            return "One or more external widget documents are invalid."
        case .unreadableStorage:
            return "External widget storage could not be read safely."
        case .registrationConflict:
            return "External widgets could not be registered because of a widget registration conflict."
        case .unknown:
            return "External widgets could not be loaded safely."
        }
    }
}
