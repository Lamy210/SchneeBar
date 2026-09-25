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
