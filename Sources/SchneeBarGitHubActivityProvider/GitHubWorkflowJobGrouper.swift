import Foundation
import SchneeBarGitHub

public struct GitHubWorkflowJobVariant: Equatable, Sendable {
    public let label: String
    public let job: GitHubWorkflowJob

    public init(label: String, job: GitHubWorkflowJob) {
        self.label = label
        self.job = job
    }
}

public struct GitHubWorkflowJobVariantGroup: Equatable, Sendable {
    public let runID: Int64
    public let baseName: String
    public let variants: [GitHubWorkflowJobVariant]

    public init(
        runID: Int64,
        baseName: String,
        variants: [GitHubWorkflowJobVariant]
    ) {
        self.runID = runID
        self.baseName = baseName
        self.variants = variants
    }
}

public enum GitHubWorkflowJobPresentationEntry: Equatable, Sendable {
    case job(GitHubWorkflowJob)
    case variantGroup(GitHubWorkflowJobVariantGroup)
}

public struct GitHubWorkflowJobGrouper: Sendable {
    public init() {}

    public func entries(
        jobs: [GitHubWorkflowJob]
    ) -> [GitHubWorkflowJobPresentationEntry] {
        var candidatesByKey: [GroupKey: [Candidate]] = [:]
        var standaloneJobs: [GitHubWorkflowJob] = []

        for job in jobs {
            guard let parsed = parseVariantName(job.name) else {
                standaloneJobs.append(job)
                continue
            }

            let key = GroupKey(runID: job.runID, baseName: parsed.baseName)
            candidatesByKey[key, default: []].append(
                Candidate(job: job, variantLabel: parsed.variantLabel)
            )
        }

        var result = standaloneJobs.map(GitHubWorkflowJobPresentationEntry.job)

        for (key, candidates) in candidatesByKey {
            let labels = candidates.map(\.variantLabel)
            let canGroup = candidates.count >= 2 && Set(labels).count == candidates.count

            if canGroup {
                let variants = candidates
                    .map { GitHubWorkflowJobVariant(label: $0.variantLabel, job: $0.job) }
                    .sorted(by: variantPrecedes)
                result.append(
                    .variantGroup(
                        GitHubWorkflowJobVariantGroup(
                            runID: key.runID,
                            baseName: key.baseName,
                            variants: variants
                        )
                    )
                )
            } else {
                result.append(contentsOf: candidates.map { .job($0.job) })
            }
        }

        return result.sorted(by: entryPrecedes)
    }

    private func parseVariantName(_ rawName: String) -> GitHubWorkflowJobVariantName? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.last == ")" else {
            return nil
        }

        var depth = 0
        var index = name.index(before: name.endIndex)
        var openingIndex: String.Index?

        while true {
            let character = name[index]
            if character == ")" {
                depth += 1
            } else if character == "(" {
                depth -= 1
                if depth == 0 {
                    openingIndex = index
                    break
                }
                if depth < 0 {
                    return nil
                }
            }

            guard index > name.startIndex else {
                break
            }
            index = name.index(before: index)
        }

        guard depth == 0, let openingIndex else {
            return nil
        }
        guard openingIndex > name.startIndex else {
            return nil
        }

        let separatorIndex = name.index(before: openingIndex)
        guard name[separatorIndex] == " " else {
            return nil
        }

        let base = String(name[..<separatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let variantStart = name.index(after: openingIndex)
        let variantEnd = name.index(before: name.endIndex)
        let variant = String(name[variantStart..<variantEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !base.isEmpty, !variant.isEmpty, hasBalancedParentheses(base) else {
            return nil
        }

        return GitHubWorkflowJobVariantName(
            baseName: base,
            variantLabel: variant
        )
    }

    private func hasBalancedParentheses(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 {
                    return false
                }
            }
        }
        return depth == 0
    }

    private func variantPrecedes(
        _ lhs: GitHubWorkflowJobVariant,
        _ rhs: GitHubWorkflowJobVariant
    ) -> Bool {
        if lhs.label != rhs.label {
            return lhs.label < rhs.label
        }
        return lhs.job.id < rhs.job.id
    }

    private func entryPrecedes(
        _ lhs: GitHubWorkflowJobPresentationEntry,
        _ rhs: GitHubWorkflowJobPresentationEntry
    ) -> Bool {
        let left = sortKey(for: lhs)
        let right = sortKey(for: rhs)

        if left.name != right.name {
            return left.name < right.name
        }
        return left.stableID < right.stableID
    }

    private func sortKey(
        for entry: GitHubWorkflowJobPresentationEntry
    ) -> (name: String, stableID: Int64) {
        switch entry {
        case let .job(job):
            return (jobFamilyName(job.name), job.id)
        case let .variantGroup(group):
            return (group.baseName, group.variants.map(\.job.id).min() ?? 0)
        }
    }

    private func jobFamilyName(_ rawName: String) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = name.range(of: " (") else {
            return name
        }

        let prefix = String(name[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? name : prefix
    }
}

private struct GitHubWorkflowJobVariantName: Equatable, Sendable {
    let baseName: String
    let variantLabel: String
}

private struct GroupKey: Hashable {
    let runID: Int64
    let baseName: String
}

private struct Candidate {
    let job: GitHubWorkflowJob
    let variantLabel: String
}
