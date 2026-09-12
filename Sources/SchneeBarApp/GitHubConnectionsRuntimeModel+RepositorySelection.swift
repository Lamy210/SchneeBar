import Foundation
import SchneeBarGitHubFeature

@MainActor
extension GitHubConnectionsRuntimeModel {
    @discardableResult
    func saveValidatedRepositorySelection(
        profileID: UUID,
        mode: GitHubRepositorySelectionPresentationMode,
        selectedRepositoryIDs: Set<Int64>
    ) async -> Bool {
        switch mode {
        case .allAccessible:
            return await saveRepositorySelection(
                profileID: profileID,
                mode: mode,
                selectedRepositoryIDs: []
            )

        case .selected:
            guard let management = managementModel(profileID: profileID),
                  !management.repositories.isEmpty
            else {
                return false
            }

            let accessibleIDs = Set(management.repositories.map(\.id))
            let validatedIDs = selectedRepositoryIDs.intersection(accessibleIDs)
            return await saveRepositorySelection(
                profileID: profileID,
                mode: mode,
                selectedRepositoryIDs: validatedIDs
            )
        }
    }
}
