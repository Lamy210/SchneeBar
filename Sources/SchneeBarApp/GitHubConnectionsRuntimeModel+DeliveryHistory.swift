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

            let scope = DeliveryHistoryStorageScope(
                sourceID: profile.id.uuidString,
                repositoryID: String(repository.id)
            )
            let cached = try? await deliveryHistoryStore.load(
                scope: scope
            )

            guard actionsAccessPresentation(
                profileID: profile.id,
                repositoryID: repository.id
            ) != .unavailable else {
                if let cached {
                    return cached
                }
                throw DeliveryHistoryLoadingError.actionsUnavailable
            }

            do {
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

                let live = historyMapper.map(
                    repository: repository,
                    runs: runs
                )
                let merged = DeliveryHistoryMerger(
                    maximumEntries: 200
                ).merge(
                    cached: cached,
                    live: live
                )
                try? await deliveryHistoryStore.save(
                    merged,
                    scope: scope
                )
                return merged
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let cached {
                    return cached
                }
                throw error
            }
        }

        throw DeliveryHistoryLoadingError.activityContextUnavailable
    }
}

private enum DeliveryHistoryLoadingError: Error {
    case unsupportedActivity
    case actionsUnavailable
    case activityContextUnavailable
}
