import Foundation

public enum ActivityPresentationTextRole: Sendable {
    case repository
    case title
    case detail
}

public enum ActivityPresentationTextPolicy {
    public static func allows(
        _ value: String,
        role: ActivityPresentationTextRole
    ) -> Bool {
        let budget = budget(for: role)

        return !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && value.count <= budget.maximumCharacters
            && value.utf8.count <= budget.maximumUTF8Bytes
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    public static func allowsOptional(
        _ value: String?,
        role: ActivityPresentationTextRole
    ) -> Bool {
        guard let value else {
            return true
        }
        return allows(value, role: role)
    }

    public static func allows(
        _ detail: ActivityDetailSnapshot
    ) -> Bool {
        guard allows(detail.repository, role: .repository),
              allows(detail.title, role: .title),
              allows(detail.summary, role: .detail),
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
        _ timeline: DeliveryTimelineSnapshot
    ) -> Bool {
        timeline.events.allSatisfy {
            allows($0.title, role: .title)
                && allowsOptional($0.detail, role: .detail)
        }
            && timeline.evidence.allSatisfy {
                allows($0.title, role: .title)
                    && allowsOptional($0.detail, role: .detail)
            }
    }

    public static func allows(
        _ history: DeliveryHistorySnapshot
    ) -> Bool {
        allows(history.repository, role: .repository)
            && history.entries.allSatisfy {
                allows($0.title, role: .title)
                    && allowsOptional($0.detail, role: .detail)
            }
    }

    private static func allows(
        rows: [ActivityDetailRow]
    ) -> Bool {
        var pending = rows

        while let row = pending.popLast() {
            guard allows(row.title, role: .title),
                  allowsOptional(row.detail, role: .detail)
            else {
                return false
            }
            pending.append(contentsOf: row.children)
        }

        return true
    }

    private static func budget(
        for role: ActivityPresentationTextRole
    ) -> PresentationBudget {
        switch role {
        case .repository:
            PresentationBudget(
                maximumCharacters: 512,
                maximumUTF8Bytes: 1_536
            )
        case .title:
            PresentationBudget(
                maximumCharacters: 1_024,
                maximumUTF8Bytes: 3_072
            )
        case .detail:
            PresentationBudget(
                maximumCharacters: 2_048,
                maximumUTF8Bytes: 6_144
            )
        }
    }
}

private struct PresentationBudget {
    let maximumCharacters: Int
    let maximumUTF8Bytes: Int
}
