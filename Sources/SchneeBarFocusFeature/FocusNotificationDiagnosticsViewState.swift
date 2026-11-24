import Foundation
import SchneeBarFocusNotifications
import SwiftUI

/// Explicit, testable state for the standalone developer diagnostic preview.
/// The evidence is ephemeral; nothing here acknowledges, resends, removes,
/// or persists any macOS notification.
@MainActor
public final class FocusNotificationDiagnosticsViewState: ObservableObject {
    @Published public private(set) var diagnostics: FocusReminderNotificationDiagnostics?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let reader: FocusReminderNotificationDiagnosticsReader

    public init(reader: FocusReminderNotificationDiagnosticsReader) {
        self.reader = reader
    }

    /// A refresh replaces the previous state rather than retaining a stale
    /// summary while two non-atomic OS lists and the local snapshot are read.
    public func refresh() async {
        guard !isLoading else { return }
        diagnostics = nil
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            diagnostics = try await reader.load()
        } catch {
            diagnostics = nil
            // Do not expose error payloads or raw identifiers in the UI.
            errorMessage = "Evidence could not be verified. Refresh to retry; no notification was changed."
        }
    }
}
