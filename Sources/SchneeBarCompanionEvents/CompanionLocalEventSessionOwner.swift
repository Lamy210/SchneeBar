import Foundation

/// Owns exactly one explicitly requested transport registration. Replacing a
/// session invalidates callbacks before stopping the old registration.
@MainActor
public final class CompanionLocalEventSessionOwner {
    public typealias Receive = CompanionLocalNotificationSubscription.Receive
    typealias Stop = @MainActor () -> Void
    typealias Open = @MainActor (UUID, @escaping Receive) -> Stop

    private let open: Open
    private let receive: Receive
    private var close: Stop?
    private var generation = UUID()
    public private(set) var session: UUID?

    public convenience init(receive: @escaping Receive) {
        self.init(open: { session, receive in
            let subscription = CompanionLocalNotificationSubscription(session: session, receive: receive)
            subscription.start()
            return { subscription.stop() }
        }, receive: receive)
    }

    init(open: @escaping Open, receive: @escaping Receive) {
        self.open = open
        self.receive = receive
    }

    /// nil revokes reception. Repeating the same session is a no-op.
    /// A synchronous callback during registration may revoke the session;
    /// in that case close the returned registration rather than installing it.
    public func update(session next: UUID?) {
        guard session != next else { return }
        let token = UUID()
        generation = token
        session = next
        let previous = close
        close = nil
        previous?()
        guard generation == token, let next else { return }
        let registration = open(next) { [weak self] received, kind, object in
            guard let self, self.generation == token,
                  self.session == next, received == next else { return }
            self.receive(received, kind, object)
        }
        if generation == token {
            close = registration
        } else {
            registration()
        }
    }

    public func stop() { update(session: nil) }

    isolated deinit { close?() }
}
