import AppKit
import Foundation

/// Borrows only an existing button's image. Does not create a status item,
/// own the button or change its title, action, tooltip or accessibility label.
@MainActor
public final class CompanionStatusImageSurface {
    public struct Session: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private weak var button: NSButton?
    private var session: Session?
    private var original: NSImage?
    private var expected: NSImage?
    private var displayed = false

    public init() {}

    /// Composition root must establish exclusive image ownership first.
    /// Starting a new session ends the previous one without retaining its button.
    public func begin(on button: NSButton) -> Session {
        stop()
        let next = Session(id: UUID())
        self.button = button
        self.session = next
        original = button.image
        expected = button.image
        return next
    }

    /// False means stale session, vanished button or external image replacement.
    /// Explicit reacquisition is required after ownership is lost.
    @discardableResult
    public func present(_ image: NSImage, in token: Session) -> Bool {
        guard let button = currentButton(for: token) else { return false }
        button.image = image
        expected = button.image
        displayed = true
        return true
    }

    /// Restore the original image without ending a still-valid session.
    /// Idempotent; permits a subsequent renderer frame after a temporary clear.
    @discardableResult
    public func clear(in token: Session) -> Bool {
        guard let button = currentButton(for: token) else { return false }
        if displayed {
            button.image = original
            expected = button.image
            displayed = false
        }
        return true
    }

    public func end(_ token: Session) {
        guard session == token else { return }
        stop()
    }

    /// The owning composition must call this before releasing its surface.
    public func stop() {
        if let token = session { _ = clear(in: token) }
        relinquish()
    }

    private func currentButton(for token: Session) -> NSButton? {
        guard session == token else { return nil }
        guard let button, button.image === expected else {
            // A different writer has taken the image slot, or the host vanished.
            // Never overwrite its image in an attempt to restore our baseline.
            relinquish()
            return nil
        }
        return button
    }

    private func relinquish() {
        button = nil
        session = nil
        original = nil
        expected = nil
        displayed = false
    }
}
