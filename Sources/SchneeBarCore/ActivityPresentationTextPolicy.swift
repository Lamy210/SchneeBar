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
