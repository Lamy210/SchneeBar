import Foundation

public struct ActivityInboxOrdering: Sendable {
    public init() {}

    public func areInIncreasingOrder(
        _ lhs: ActivityItem,
        _ rhs: ActivityItem
    ) -> Bool {
        let lhsAttention = attentionRank(lhs.attention)
        let rhsAttention = attentionRank(rhs.attention)
        if lhsAttention != rhsAttention {
            return lhsAttention < rhsAttention
        }

        let lhsState = stateRank(lhs.state)
        let rhsState = stateRank(rhs.state)
        if lhsState != rhsState {
            return lhsState < rhsState
        }

        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.repository != rhs.repository {
            return lhs.repository < rhs.repository
        }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.id < rhs.id
    }

    private func attentionRank(_ attention: ActivityAttention) -> Int {
        switch attention {
        case .actionRequired: 0
        case .needsAttention: 1
        case .active: 2
        case .informational: 3
        }
    }

    private func stateRank(_ state: ActivityState) -> Int {
        switch state {
        case .failed: 0
        case .running: 1
        case .waiting: 2
        case .success: 3
        }
    }
}
