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
