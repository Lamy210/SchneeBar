import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider

@MainActor
extension GitHubConnectionsRuntimeModel {
    func loadDeliveryHistory(
        for item: ActivityItem,
        workflowRunLoader: any GitHubWorkflowRunLoading,
        historyMapper: GitHubDeliveryHistoryMapper = GitHubDeliveryHistoryMapper()
    ) async throws -> DeliveryHistorySnapshot {
        guard item.kind == .workflowRun,
              let destinationURL = item.destinationURL
        else {
            throw DeliveryHistoryLoadingError.unsupportedActivity
        }

        let destinationHost = destinationURL.host?.lowercased()
        let destinationPort = destinationURL.port

        for profile in profiles where profile.isEnabled {
            let endpoints = try GitHubEndpointResolver.resolve(
                deploymentKind: profile.connection.deploymentKind,
                webBaseURL: profile.connection.webBaseURL
            )
            guard endpoints.webBaseURL.host?.lowercased() == destinationHost,
                  endpoints.webBaseURL.port == destinationPort,
                  let repository = repositoryAccess(
                      profileID: profile.id,
                      fullName: item.repository
                  )
            else {
                continue
            }

            guard actionsAccessPresentation(
                profileID: profile.id,
                repositoryID: repository.id
            ) != .unavailable else {
                throw DeliveryHistoryLoadingError.actionsUnavailable
            }

            let runs = try await workflowRunLoader.workflowRuns(
                connection: profile.connection,
                identity: profile.account,
                clientID: profile.clientID,
                repository: repository,
                query: GitHubWorkflowRunQuery(
                    status: .completed,
                    limit: 20
                )
            )

            return historyMapper.map(
                repository: repository,
                runs: runs
            )
        }

        throw DeliveryHistoryLoadingError.activityContextUnavailable
    }
}

private enum DeliveryHistoryLoadingError: Error {
    case unsupportedActivity
    case actionsUnavailable
    case activityContextUnavailable
}
