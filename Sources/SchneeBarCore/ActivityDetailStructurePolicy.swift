import Foundation

public enum ActivityDetailStructurePolicy {
    public static func allows(
        _ detail: ActivityDetailSnapshot,
        selectedItem: ActivityItem
    ) -> Bool {
        guard detail.id == selectedItem.id,
              detail.repository == selectedItem.repository,
              hasUniqueActions(detail.actions),
              allows(rows: detail.rows)
        else {
            return false
        }

        guard let timeline = detail.deliveryTimeline else {
            return true
        }
        return allows(timeline)
    }

    public static func allows(
        _ history: DeliveryHistorySnapshot,
        selectedItem: ActivityItem
    ) -> Bool {
        guard history.repository == selectedItem.repository else {
            return false
        }

        return hasUniqueValidIDs(
            history.entries.lazy.map(\.id)
        )
    }

    private static func allows(
        _ timeline: DeliveryTimelineSnapshot
    ) -> Bool {
        hasUniqueValidIDs(timeline.events.lazy.map(\.id))
            && hasUniqueValidIDs(timeline.evidence.lazy.map(\.id))
    }

    private static func allows(
        rows: [ActivityDetailRow]
    ) -> Bool {
        var pending: [(rows: [ActivityDetailRow], depth: Int)] = [
            (rows, 1),
        ]

        while let group = pending.popLast() {
            guard hasUniqueValidIDs(
                group.rows.lazy.map(\.id)
            ) else {
                return false
            }

            for row in group.rows {
                if group.depth >= 2 {
                    guard row.children.isEmpty else {
                        return false
                    }
                } else if !row.children.isEmpty {
                    pending.append((row.children, group.depth + 1))
                }
            }
        }

        return true
    }

    private static func hasUniqueActions(
        _ actions: [ActivityDetailAction]
    ) -> Bool {
        Set(actions).count == actions.count
    }

    private static func hasUniqueValidIDs<IDs: Sequence>(
        _ ids: IDs
    ) -> Bool where IDs.Element == String {
        var seen = Set<String>()

        for id in ids {
            guard isValidID(id),
                  seen.insert(id).inserted
            else {
                return false
            }
        }

        return true
    }

    private static func isValidID(
        _ id: String
    ) -> Bool {
        !id.isEmpty
            && id.utf8.count <= 256
            && !id.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}
