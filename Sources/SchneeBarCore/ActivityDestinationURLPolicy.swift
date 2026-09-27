import Foundation

public enum ActivityDestinationURLPolicy {
    public static func allows(_ url: URL?) -> Bool {
        guard let url else {
            return true
        }

        return url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }

    public static func allows(_ row: ActivityDetailRow) -> Bool {
        allows(row.destinationURL)
            && row.children.allSatisfy { allows($0) }
    }

    public static func allows(_ timeline: DeliveryTimelineSnapshot) -> Bool {
        timeline.events.allSatisfy {
            allows($0.destinationURL)
        }
    }

    public static func allows(_ detail: ActivityDetailSnapshot) -> Bool {
        guard allows(detail.destinationURL),
              detail.rows.allSatisfy({ allows($0) })
        else {
            return false
        }

        guard let timeline = detail.deliveryTimeline else {
            return true
        }
        return allows(timeline)
    }

    public static func allows(_ history: DeliveryHistorySnapshot) -> Bool {
        history.entries.allSatisfy {
            allows($0.destinationURL)
        }
    }
}
