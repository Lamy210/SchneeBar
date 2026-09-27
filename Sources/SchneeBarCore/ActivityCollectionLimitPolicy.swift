public enum ActivityCollectionLimitPolicy {
    public static let maximumDetailNodes = 1_024
    public static let maximumTimelineEvents = 32
    public static let maximumTimelineEvidenceItems = 32
    public static let maximumHistoryEntries = 200

    public static func allows(
        _ detail: ActivityDetailSnapshot
    ) -> Bool {
        guard allows(rows: detail.rows) else {
            return false
        }

        guard let timeline = detail.deliveryTimeline else {
            return true
        }

        return timeline.events.count <= maximumTimelineEvents
            && timeline.evidence.count <= maximumTimelineEvidenceItems
    }

    public static func allows(
        _ history: DeliveryHistorySnapshot
    ) -> Bool {
        history.entries.count <= maximumHistoryEntries
    }

    private static func allows(
        rows: [ActivityDetailRow]
    ) -> Bool {
        guard rows.count <= maximumDetailNodes else {
            return false
        }

        var pending = rows
        var processed = 0

        while let row = pending.popLast() {
            processed += 1
            guard processed <= maximumDetailNodes else {
                return false
            }

            guard processed
                + pending.count
                + row.children.count
                <= maximumDetailNodes
            else {
                return false
            }

            pending.append(contentsOf: row.children)
        }

        return true
    }
}
