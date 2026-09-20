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
        timelineBuilder: GitHubDeliveryTimelineBuilder = GitHubDeliveryTimelineBuilder(),
        detailMapper: GitHubActivityJobDetailMapper = GitHubActivityJobDetailMapper()
    ) async throws -> ActivityDetailSnapshot {
        guard let destinationURL = item.destinationURL,
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
                  endpoints.webBaseURL.port == destinationPort
            else {
                continue
            }

            guard let management = managementModel(profileID: profile.id),
                  let option = management.repositories.first(where: {
                      $0.fullName == item.repository
                  }),
                  let repository = makeRepository(
                      option: option,
                      webBaseURL: endpoints.webBaseURL
                  )
            else {
                continue
            }

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
                        deliveryTimeline = timelineBuilder.appendDeployments(
                            to: deliveryTimeline,
                            evidence: deploymentEvidence
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
                    events: []
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
                rows: jobDetail.rows
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

    private func makeRepository(
        option: GitHubRepositoryOptionModel,
        webBaseURL: URL
    ) -> GitHubRepositoryAccess? {
        let components = option.fullName.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }

        let owner = String(components[0])
        let name = String(components[1])
        let webURL = webBaseURL
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)

        return GitHubRepositoryAccess(
            id: option.id,
            name: name,
            fullName: option.fullName,
            isPrivate: option.isPrivate,
            webURL: webURL,
            ownerLogin: owner,
            permissions: GitHubRepositoryPermissions(pull: true)
        )
    }
}

private enum ActivityDetailLoadingError: Error {
    case unsupportedActivity
    case activityContextUnavailable
}
