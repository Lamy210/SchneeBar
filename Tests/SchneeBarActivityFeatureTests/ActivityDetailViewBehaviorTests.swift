import Foundation
@testable import SchneeBarActivityFeature
import SchneeBarCore
import Testing

@Test
func activityDetailRowInteractionPrefersDisclosureForChildren() {
    let child = ActivityDetailRow(
        id: "child",
        title: "macos",
        detail: "Failed",
        state: .failed,
        destinationURL: URL(string: "https://github.com/octocat/project/actions/runs/1/job/11")
    )
    let row = ActivityDetailRow(
        id: "group",
        title: "Test",
        detail: "2 variants · 1 failed",
        state: .failed,
        destinationURL: URL(string: "https://github.com/octocat/project/actions/runs/1"),
        children: [child]
    )

    #expect(activityDetailRowInteraction(row) == .disclosure)
}

@Test
func activityDetailRowInteractionUsesLinkForChildlessDestination() throws {
    let destination = try #require(
        URL(string: "https://github.com/octocat/project/actions/runs/1/job/11")
    )
    let row = ActivityDetailRow(
        id: "11",
        title: "Build",
        detail: "Succeeded",
        state: .success,
        destinationURL: destination
    )

    #expect(activityDetailRowInteraction(row) == .link(destination))
}

@Test
func activityDetailRowInteractionUsesNoneForPlainRow() {
    let row = ActivityDetailRow(
        id: "plain",
        title: "Build",
        detail: nil,
        state: .neutral
    )

    #expect(activityDetailRowInteraction(row) == .none)
}
