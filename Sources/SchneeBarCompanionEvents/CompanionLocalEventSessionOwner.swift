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
    private var registeredGeneration: UUID?
    private var reconciling = false
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

    /// nil revokes reception immediately. Reentrant updates change desired
    /// state only; the outer registration transition drains before any new
    /// transport opens. Even a reused session UUID gets a new generation.
    public func update(session next: UUID?) {
        guard session != next else { return }
        generation = UUID()
        session = next
        reconcile()
    }

    private func reconcile() {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        while true {
            if let previous = close {
                if registeredGeneration == generation { return }
                close = nil
                registeredGeneration = nil
                previous()
                // Closing can synchronously change the desired session.
                continue
            }
            guard let next = session else { return }
            let token = generation
            let registration = open(next) { [weak self] received, kind, object in
                guard let self, self.generation == token,
                      self.session == next, received == next else { return }
                self.receive(received, kind, object)
            }
            if generation == token {
                close = registration
                registeredGeneration = token
                return
            }
            // The open call returned after revocation/replacement.
            // Close it completely before opening the latest desired session.
            registration()
        }
    }

    public func stop() { update(session: nil) }

    isolated deinit { close?() }
}
