import Foundation
import SchneeBarCompanionCore
import Testing

@Test func cpuInputDoesNotApplySameSampleTwice() throws {
    var input = CompanionCPUInput()
    input.setMode(.automatic)
    let epoch = UUID()
    let now = ContinuousClock.now
    let firstID = UUID()
    let a = input.beginRequest()
    let first = try #require(a)
    #expect((input.accept(first, id: firstID, epoch: epoch, capturedAt: now, hostPercentage: 50)) == true)
    let b = input.beginRequest()
    let second = try #require(b)
    #expect((input.accept(second, id: firstID, epoch: epoch, capturedAt: now, hostPercentage: 0)) == false)
    #expect(input.reaction?.smoothedFraction == 0.5)
    let c = input.beginRequest()
    let third = try #require(c)
    #expect((input.accept(third, id: UUID(), epoch: epoch, capturedAt: now.advanced(by: .seconds(5)), hostPercentage: 0)) == true)
    #expect(input.reaction?.smoothedFraction == 0.375)
}

@Test func cpuInputFencesRequestsFromOldModeAndSession() throws {
    var input = CompanionCPUInput()
    input.setMode(.automatic)
    let oldCandidate = input.beginRequest()
    let old = try #require(oldCandidate)
    input.setMode(.manual(.double))
    #expect(input.reaction == nil)
    #expect(input.rate == .double)
    let manualRequest = input.beginRequest()
    #expect(manualRequest == nil)
    #expect((input.unavailable(old)) == false)
    input.setMode(.automatic)
    let newCandidate = input.beginRequest()
    let new = try #require(newCandidate)
    #expect((input.accept(old, id: UUID(), epoch: UUID(), capturedAt: .now, hostPercentage: 100)) == false)
    #expect((input.accept(new, id: UUID(), epoch: UUID(), capturedAt: .now, hostPercentage: 50)) == true)
    #expect(input.rate == .normal)
    input.invalidateSession()
    #expect(input.reaction == nil)
    #expect((input.unavailable(new)) == false)
}

@Test func cpuInputRejectsOlderResultsAndClearsOnFailure() throws {
    var input = CompanionCPUInput()
    input.setMode(.automatic)
    let epoch = UUID()
    let now = ContinuousClock.now
    let firstCandidate = input.beginRequest()
    let first = try #require(firstCandidate)
    let secondCandidate = input.beginRequest()
    let second = try #require(secondCandidate)
    let id = UUID()
    #expect((input.accept(second, id: id, epoch: epoch, capturedAt: now, hostPercentage: 95)) == true)
    #expect((input.unavailable(first)) == false)
    #expect(input.reaction?.state == .sprint)
    let failureCandidate = input.beginRequest()
    let failure = try #require(failureCandidate)
    #expect((input.unavailable(failure)) == true)
    #expect(input.reaction == nil)
    let duplicateCandidate = input.beginRequest()
    let duplicate = try #require(duplicateCandidate)
    #expect((input.accept(duplicate, id: id, epoch: epoch, capturedAt: now, hostPercentage: 95)) == false)
    let freshCandidate = input.beginRequest()
    let fresh = try #require(freshCandidate)
    #expect((input.accept(fresh, id: UUID(), epoch: UUID(), capturedAt: now.advanced(by: .seconds(5)), hostPercentage: 0)) == true)
    #expect(input.reaction?.state == .idle)
}
