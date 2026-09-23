import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature

@MainActor
extension GitHubConnectionsRuntimeModel {
    func loadActivityDetail(
        for item: ActivityItem,
        jobService: GitHubWorkflowJobService,
        timelineLoader: any GitHubDeliveryTimelineLoading,
        deploymentTimelineLoader: any GitHubDeploymentTimelineLoading,
        environmentCatalogLoader: any GitHubEnvironmentCatalogLoading,
        timelineBuilder: GitHubDeliveryTimelineBuilder = GitHubDeliveryTimelineBuilder(),
        detailMapper: GitHubActivityJobDetailMapper = GitHubActivityJobDetailMapper()
    ) async throws -> ActivityDetailSnapshot {
        let context = try workflowActivityContext(for: item)
        let profile = context.profile
        let repository = context.repository
        let runID = context.runID

        let jobs = try await jobService.jobs(
            connection: profile.connection,
            identity: profile.account,
            clientID: profile.clientID,
            repository: repository,
            runID: runID,
            query: GitHubWorkflowJobQuery(filter: .latest, limit: 100)
        )
        let jobDetail = detailMapper.map(item: item, jobs: jobs)

        var deliveryTimeline: DeliveryTimelineSnapshot
        do {
            let evidence = try await timelineLoader.timelineEvidence(
                connection: profile.connection,
                identity: profile.account,
                clientID: profile.clientID,
                repository: repository,
                runID: runID
            )
            let buildResult = timelineBuilder.buildResult(
                repositoryID: repository.id,
                evidence: evidence
            )
            deliveryTimeline = buildResult.timeline

            if let baseRun = buildResult.correlatedBaseRun,
               deploymentAccessPresentation(
                   profileID: profile.id,
                   repositoryID: repository.id
               ) != .unavailable
            {
                do {
                    let deploymentEvidence = try await deploymentTimelineLoader.deploymentEvidence(
                        connection: profile.connection,
                        identity: profile.account,
                        clientID: profile.clientID,
                        repository: repository,
                        exactSHA: baseRun.headSHA
                    )

                    var environmentCatalog: GitHubEnvironmentCatalog?
                    if !deploymentEvidence.deployments.isEmpty,
                       actionsAccessPresentation(
                           profileID: profile.id,
                           repositoryID: repository.id
                       ) != .unavailable
                    {
                        do {
                            environmentCatalog = try await environmentCatalogLoader.environmentCatalog(
                                connection: profile.connection,
                                identity: profile.account,
                                clientID: profile.clientID,
                                repository: repository
                            )
                        } catch let cancellation as CancellationError {
                            throw cancellation
                        } catch {
                            // Environment enrichment is best effort.
                            // Preserve the already-proven Deployment evidence.
                            environmentCatalog = nil
                        }
                    }

                    deliveryTimeline = timelineBuilder.appendDeployments(
                        to: deliveryTimeline,
                        evidence: deploymentEvidence,
                        environmentCatalog: environmentCatalog
                    )
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    // Deployment enrichment is best effort. Preserve the
                    // already-correlated delivery timeline.
                }
            }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            deliveryTimeline = DeliveryTimelineSnapshot(
                status: .temporarilyUnavailable,
                confidence: .unknown,
                events: [],
                evidence: [
                    DeliveryTimelineEvidenceItem(
                        id: "delivery-evidence-load",
                        title: "Delivery evidence",
                        detail: "GitHub evidence could not be loaded right now",
                        state: .unavailable
                    ),
                ]
            )
        }

        return ActivityDetailSnapshot(
            id: jobDetail.id,
            repository: jobDetail.repository,
            title: jobDetail.title,
            summary: jobDetail.summary,
            state: jobDetail.state,
            destinationURL: jobDetail.destinationURL,
            deliveryTimeline: deliveryTimeline,
            actions: workflowRunDetailActions(
                for: item.state,
                writeAccess: workflowWriteAccessPresentation(
                    profileID: profile.id,
                    repositoryID: repository.id
                )
            ),
            rows: jobDetail.rows
        )
    }

    func workflowActivityContext(
        for item: ActivityItem
    ) throws -> GitHubWorkflowActivityContext {
        guard item.kind == .workflowRun,
              let destinationURL = item.destinationURL,
              let runID = workflowRunID(from: destinationURL)
        else {
            throw ActivityDetailLoadingError.unsupportedActivity
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

            return GitHubWorkflowActivityContext(
                profile: profile,
                repository: repository,
                runID: runID
            )
        }

        throw ActivityDetailLoadingError.activityContextUnavailable
    }

    private func workflowRunID(from url: URL) -> Int64? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let runsIndex = components.lastIndex(of: "runs"),
              components.indices.contains(runsIndex + 1)
        else {
            return nil
        }
        return Int64(components[runsIndex + 1])
    }

}

struct GitHubWorkflowActivityContext {
    let profile: GitHubConnectionProfile
    let repository: GitHubRepositoryAccess
    let runID: Int64
}

func workflowRunDetailActions(
    for state: ActivityState,
    writeAccess: GitHubRepositoryActivityAccessPresentation
) -> [ActivityDetailAction] {
    guard writeAccess == .available else {
        return []
    }

    switch state {
    case .running, .waiting:
        return [.cancelWorkflow]
    case .failed, .success:
        return [.rerunWorkflow]
    }
}

enum ActivityDetailLoadingError: Error {
    case unsupportedActivity
    case activityContextUnavailable
}
