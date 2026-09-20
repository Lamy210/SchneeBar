import Foundation
import SchneeBarCore
import Testing

@Test
func deliveryRecoveryEventPreservesNormalizedContext() throws {
    let destination = try #require(
        URL(string: "https://github.com/snow/repo/actions/runs/901")
    )
    let event = DeliveryRecoveryEvent(
        id: "github-delivery-recovery:42:88:pull_request:47:901",
        repository: "snow/repo",
        title: "CI recovered",
        detail: "PR #47 succeeded after a previously observed failed workflow run",
        destinationURL: destination,
        occurredAt: Date(timeIntervalSince1970: 901)
    )

    #expect(event.id == "github-delivery-recovery:42:88:pull_request:47:901")
    #expect(event.repository == "snow/repo")
    #expect(event.title == "CI recovered")
    #expect(event.detail == "PR #47 succeeded after a previously observed failed workflow run")
    #expect(event.destinationURL == destination)
    #expect(event.occurredAt == Date(timeIntervalSince1970: 901))
}
