import Foundation
import SchneeBarCompanionCore
import Testing

@Test func fixedPrecedenceAndFallback() {
    var policy = CompanionArbitration()
    let advisory = CompanionSource.systemAdvisory(UUID())
    let system = CompanionSource.systemEvent(UUID())
    let local = CompanionSource.localState(UUID())
    #expect(policy.state == .run)
    #expect(policy.winningSource == nil)
    #expect(CompanionSource.cpu.priority == 100)
    #expect(advisory.priority == 300)
    #expect(system.priority == 400)
    #expect(local.priority == 500)
    #expect(CompanionSource.manual.priority == 1000)
    #expect((policy.submit(.walk, from: .cpu, at: .zero)) == true)
    #expect((policy.submit(.idle, from: advisory, at: .zero)) == true)
    #expect((policy.submit(.run, from: system, at: .zero)) == true)
    #expect((policy.submit(.dash, from: local, at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.sprint, from: .manual, at: .zero)) == true)
    #expect(policy.state == .sprint)
    policy.clear(.manual)
    #expect(policy.winningSource == local)
    policy.clear(local)
    #expect(policy.winningSource == system)
    policy.clear(system)
    #expect(policy.winningSource == advisory)
    policy.clear(advisory)
    #expect(policy.winningSource == .cpu)
    policy.clear(.cpu)
    #expect(policy.state == .run)
}

@Test func equalPriorityUsesMostRecentlyAcceptedIdentity() {
    var policy = CompanionArbitration()
    let first = CompanionSource.localState(UUID())
    let second = CompanionSource.developer(UUID())
    #expect((policy.submit(.walk, from: first, at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.dash, from: second, at: .zero)) == true)
    #expect(policy.winningSource == second)
    #expect((policy.submit(.sprint, from: first, at: .zero, until: .seconds(20))) == true)
    #expect(policy.winningSource == first)
    policy.clear(first)
    #expect(policy.winningSource == second)
}

@Test func renewalAndMonotonicExpiry() {
    var policy = CompanionArbitration()
    #expect((policy.submit(.dash, from: .localBuild, at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.sprint, from: .localBuild, at: .seconds(5), until: .seconds(20))) == true)
    #expect(policy.nextDeadline == .seconds(20))
    #expect((policy.advance(to: .seconds(10))) == true)
    #expect(policy.state == .sprint)
    #expect((policy.advance(to: .seconds(20))) == true)
    #expect(policy.state == .run)
    #expect(policy.nextDeadline == nil)
    #expect((policy.advance(to: .seconds(19))) == false)
    #expect((policy.submit(.idle, from: .manual, at: .seconds(19))) == false)
    #expect(policy.state == .run)
}

@Test func admissionReservesManualAndCPUAndAllowsReplacement() {
    var policy = CompanionArbitration()
    let local = CompanionSource.localState(UUID())
    #expect((policy.submit(.walk, from: local, at: .zero, until: .seconds(10))) == true)
    for _ in 0..<62 {
        #expect((policy.submit(.dash, from: .localState(UUID()), at: .zero, until: .seconds(10))) == true)
    }
    #expect((policy.submit(.dash, from: .localBuild, at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.dash, from: .localState(UUID()), at: .zero, until: .seconds(10))) == false)
    for _ in 0..<62 {
        #expect((policy.submit(.dash, from: .developer(UUID()), at: .zero)) == true)
    }
    let excess = CompanionSource.systemEvent(UUID())
    #expect((policy.submit(.idle, from: excess, at: .zero)) == false)
    #expect((policy.submit(.sprint, from: local, at: .zero, until: .seconds(20))) == true)
    #expect(policy.winningSource == local)
    #expect((policy.submit(.walk, from: .cpu, at: .zero)) == true)
    #expect((policy.submit(.idle, from: .manual, at: .zero)) == true)
    #expect(policy.winningSource == .manual)
    policy.clear(local)
    #expect((policy.submit(.run, from: excess, at: .zero)) == true)
}

@Test func invalidDeadlineDoesNotReplaceLiveTrigger() {
    var policy = CompanionArbitration()
    #expect((policy.submit(.idle, from: .cpu, at: .seconds(-1))) == false)
    #expect((policy.submit(.dash, from: .localBuild, at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.idle, from: .localBuild, at: .zero)) == false)
    #expect((policy.submit(.idle, from: .localBuild, at: .seconds(1), until: .seconds(1))) == false)
    #expect((policy.submit(.idle, from: .manual, at: .seconds(1), until: .seconds(2))) == false)
    #expect(policy.state == .dash)
    #expect(policy.nextDeadline == .seconds(10))
}

@Test func localQuarantineDoesNotClearTrustedTriggers() {
    var policy = CompanionArbitration()
    let developer = CompanionSource.developer(UUID())
    let system = CompanionSource.systemEvent(UUID())
    #expect((policy.submit(.walk, from: .cpu, at: .zero)) == true)
    #expect((policy.submit(.run, from: system, at: .zero)) == true)
    #expect((policy.submit(.idle, from: developer, at: .zero)) == true)
    #expect((policy.submit(.walk, from: .productivity, at: .zero)) == true)
    #expect((policy.submit(.dash, from: .localBuild, at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.sprint, from: .localState(UUID()), at: .zero, until: .seconds(10))) == true)
    #expect((policy.submit(.idle, from: .manual, at: .zero)) == true)
    policy.clearLocal()
    #expect(policy.winningSource == .manual)
    #expect(policy.nextDeadline == nil)
    policy.clear(.manual)
    #expect(policy.winningSource == .productivity)
    policy.clear(.productivity)
    #expect(policy.winningSource == developer)
    policy.clear(developer)
    #expect(policy.winningSource == system)
    policy.clear(system)
    #expect(policy.winningSource == .cpu)
}
