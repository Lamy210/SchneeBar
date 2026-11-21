import SchneeBarCompanionCore
import Testing

@Test func cpuEMAAndNormalization() throws {
    var adaptation = CompanionCPUAdaptation()
    let initialCandidate = adaptation.accept(hostPercentage: 50)
    let initial = try #require(initialCandidate)
    #expect(initial.smoothedFraction == 0.5)
    #expect(initial.state == .run)
    #expect(initial.rate == .normal)
    let nextCandidate = adaptation.accept(hostPercentage: 0)
    let next = try #require(nextCandidate)
    #expect(next.smoothedFraction == 0.375)
    #expect(next.state == .run)
}

@Test func paceHysteresisAndMultiBandJump() {
    var pace = CompanionCPUPace()
    let first = pace.update(normalized: 0.5)
    let near = pace.update(normalized: 0.39)
    let below = pace.update(normalized: 0.36)
    let peak = pace.update(normalized: 0.95)
    #expect(first?.state == .run)
    #expect(near?.state == .run)
    #expect(below?.state == .walk)
    #expect(peak?.state == .sprint)
    #expect(peak?.rate == .double)
}

@Test func invalidCPUObservationsResetAndReseed() {
    for bad: Double? in [nil, .nan, .infinity, -.infinity, -1, 101] {
        var adaptation = CompanionCPUAdaptation()
        let peak = adaptation.accept(hostPercentage: 100)
        #expect(peak?.state == .sprint)
        let invalid = adaptation.accept(hostPercentage: bad)
        #expect(invalid == nil)
        #expect(adaptation.current == nil)
        let fresh = adaptation.accept(hostPercentage: 0)
        #expect(fresh?.smoothedFraction == 0)
        #expect(fresh?.state == .idle)
        adaptation.reset()
        #expect(adaptation.current == nil)
    }
}
