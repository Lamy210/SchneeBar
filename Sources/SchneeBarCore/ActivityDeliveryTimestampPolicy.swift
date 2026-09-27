import Foundation

public enum ActivityDeliveryTimestampPolicy {
    public static func allows(
        _ detail: ActivityDetailSnapshot
    ) -> Bool {
        guard let timeline = detail.deliveryTimeline else {
            return true
        }

        return timeline.events.allSatisfy { event in
            guard let occurredAt = event.occurredAt else {
                return true
            }
            return occurredAt.timeIntervalSinceReferenceDate.isFinite
        }
    }

    public static func allows(
        _ history: DeliveryHistorySnapshot
    ) -> Bool {
        history.entries.allSatisfy {
            $0.occurredAt.timeIntervalSinceReferenceDate.isFinite
        }
    }
}
