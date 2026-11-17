import Foundation
import SchneeBarCompanionEvents

/// Each subscription has an immutable session. Main-thread delivery is
/// documented by DistributedNotificationCenter on modern macOS. Do not
/// enqueue a separate Task per notification. No privileged action is reachable.
@MainActor
final class PreviewLocalNotificationSubscription: NSObject {
    typealias Receive = @MainActor (UUID, CompanionLocalEventIngress.Kind, Any?) -> Void
    private let center: DistributedNotificationCenter
    private let session: UUID
    private let receive: Receive
    private var listening = false

    init(session: UUID, center: DistributedNotificationCenter = .default(),
         receive: @escaping Receive) {
        self.session = session
        self.center = center
        self.receive = receive
        super.init()
    }

    func start() {
        guard !listening else { return }
        listening = true
        for kind in [CompanionLocalEventIngress.Kind.character, .build] {
            center.addObserver(self, selector: #selector(deliver(_:)),
                name: Notification.Name(kind.rawValue), object: nil,
                suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        center.removeObserver(self)
    }

    isolated deinit { center.removeObserver(self) }

    @objc private func deliver(_ note: Notification) {
        guard Thread.isMainThread, listening,
              let kind = CompanionLocalEventIngress.Kind(rawValue: note.name.rawValue) else { return }
        receive(session, kind, note.object)
    }

    /// Invoke only inside the lazy, admitted payload closure. Check UTF-16
    /// length first to bound the cost of the exact UTF-8 byte count. No
    /// conversion to an unbounded Data allocation or JSON object.
    static func boundedPayload(_ object: Any?) -> CompanionLocalEventIngress.Payload {
        guard let value = object as? NSString else { return .malformed }
        guard value.length <= 4096,
              value.lengthOfBytes(using: String.Encoding.utf8.rawValue) <= 4096 else { return .oversized }
        guard let data = value.data(using: String.Encoding.utf8.rawValue,
                                   allowLossyConversion: false) else { return .malformed }
        return .bytes(data)
    }
}
