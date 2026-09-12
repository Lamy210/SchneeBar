import Foundation
import SchneeBarCore
import SchneeBarSystemProvider
import Testing

@Test
func clockWidgetUsesInjectedTimeAndExpectedRefreshPolicy() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let provider = ClockWidgetProvider(now: { fixedDate })

    let snapshot = try await provider.snapshot()

    #expect(snapshot.descriptor.id == "system.clock")
    #expect(snapshot.generatedAt == fixedDate)
    #expect(snapshot.priority == .background)
    #expect(snapshot.severity == .nominal)
    #expect(snapshot.descriptor.refreshPolicy.interval(for: .nominal) == 30)
    #expect(!snapshot.content(for: .compact).text.isEmpty)
}

@Test
func cpuWidgetProducesBoundedPercentageAndAdaptivePriority() async throws {
    let provider = CPUWidgetProvider()
    let snapshot = try await provider.snapshot()
    let text = snapshot.content(for: .compact).text

    #expect(snapshot.descriptor.id == "system.cpu")
    #expect(snapshot.descriptor.refreshPolicy.interval(for: snapshot.severity) == 5)
    #expect(text.hasSuffix("%"))

    let numeric = text.dropLast()
    let percentage = Int(numeric)
    #expect(percentage != nil)
    if let percentage {
        #expect((0...100).contains(percentage))
    }
}
