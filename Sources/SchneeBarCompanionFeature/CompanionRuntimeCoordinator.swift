import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionEvents

/// Single-surface composition seam. Owns no AppKit status item, CPU timer,
/// filesystem permission, or persistence. The host owns demand reconciliation.
@MainActor
public final class CompanionRuntimeCoordinator {
    private let renderer: CompanionMenuBarRenderer
    /// Optional presentation-only callback. Must not reenter the coordinator.
    public var onStateChange: (@MainActor (CompanionState, CompanionPlaybackRate) -> Void)?
    private var lastPublishedState: CompanionState?
    private var lastPublishedRate: CompanionPlaybackRate?
    private var catalog: CompanionAssetCatalog?
    private var input = CompanionCPUInput()
    private var arbitration = CompanionArbitration()
    private var localIngress = CompanionLocalEventIngress()
    private var localEventsEnabled = false
    public private(set) var localEventSession: UUID?
    private let elapsed: @MainActor () -> Duration
    typealias DeadlineScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Task<Void, Never>
    private let deadlineScheduler: DeadlineScheduler
    private var scheduledDeadline: Duration?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineGeneration = UUID()
    private var preferredMode: CompanionCPUInput.Mode = .automatic
    private var enabled = false
    private var visible = false
    private var awake = true
    private var reduceMotion = false

    public convenience init(renderer: CompanionMenuBarRenderer) {
        let origin = ContinuousClock.now
        self.init(renderer: renderer, elapsed: { origin.duration(to: .now) },
            deadlineScheduler: { delay, callback in
                Task { @MainActor in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard !Task.isCancelled else { return }
                    callback()
                }
            })
    }

    // Scheduler enqueues the callback; it must not invoke it synchronously.
    init(renderer: CompanionMenuBarRenderer, elapsed: @escaping @MainActor () -> Duration,
         deadlineScheduler: @escaping DeadlineScheduler) {
        self.renderer = renderer
        self.elapsed = elapsed
        self.deadlineScheduler = deadlineScheduler
    }

    deinit { deadlineTask?.cancel() }

    private var active: Bool { enabled && visible && awake && catalog != nil }

    /// Consume this flag from the application's existing scheduler only.
    public var wantsHostCPU: Bool {
        active && !reduceMotion && preferredMode == .automatic
    }

    public var state: CompanionState { arbitration.state }
    public var rate: CompanionPlaybackRate { input.rate }
    public var displayedFrameIndex: Int? { renderer.displayedFrameIndex }

    /// Host bridge applies a complete decision before reconciling, avoiding
    /// intermediate render/CPU/event activation while inputs are being changed.
    /// The bridge exclusively owns these inputs when attached.
    func applyHostDecision(_ decision: CompanionHostPolicy.Decision,
                           catalog next: CompanionAssetCatalog?, catalogueChanged: Bool) {
        if catalogueChanged {
            input.invalidateSession()
            if localEventSession != nil {
                localEventSession = nil
                localIngress.revokeLocalState(at: elapsed(), arbitration: &arbitration)
            }
        }
        catalog = decision.rendersCharacter ? next : nil
        enabled = decision.rendersCharacter
        visible = decision.rendersCharacter
        awake = decision.rendersCharacter
        reduceMotion = decision.reduceMotion
        preferredMode = decision.mode
        localEventsEnabled = decision.listensToLocalEvents
        reconcile()
    }

    public func setCatalog(_ next: CompanionAssetCatalog?) {
        catalog = next
        input.invalidateSession()
        reconcile()
    }

    public func setPresentation(enabled: Bool, visible: Bool, awake: Bool, reduceMotion: Bool) {
        self.enabled = enabled
        self.visible = visible
        self.awake = awake
        self.reduceMotion = reduceMotion
        reconcile()
    }

    /// Playback-speed mode and manual character-state override are independent.
    public func setMode(_ mode: CompanionCPUInput.Mode) {
        preferredMode = mode
        reconcile()
    }

    public func setManualState(_ state: CompanionState?) {
        if let state {
            arbitration.submit(state, from: .manual, at: elapsed())
        } else {
            arbitration.clear(.manual, at: elapsed())
        }
        reconcile()
    }

    /// Default off. This does not register a transport or authorize actions.
    public func setLocalEventsEnabled(_ enabled: Bool) {
        localEventsEnabled = enabled
        reconcile()
    }

    /// nil means inactive, disabled or obsolete transport session.
    @discardableResult
    public func receiveLocalEvent(
        session: UUID, kind: CompanionLocalEventIngress.Kind, payload: Data
    ) -> CompanionLocalEventIngress.Outcome? {
        receiveLocalEvent(session: session, kind: kind) { .bytes(payload) }
    }

    @discardableResult
    public func receiveLocalEvent(
        session: UUID, kind: CompanionLocalEventIngress.Kind,
        payload: () -> CompanionLocalEventIngress.Payload
    ) -> CompanionLocalEventIngress.Outcome? {
        guard active, localEventsEnabled, localEventSession == session else { return nil }
        let priorState = arbitration.state
        let priorDeadline = arbitration.nextDeadline
        let outcome = localIngress.receive(
            kind: kind, at: elapsed(), arbitration: &arbitration, payload: payload
        )
        if arbitration.state != priorState || arbitration.nextDeadline != priorDeadline {
            reconcile()
        }
        return outcome
    }

    public func beginCPURequest() -> CompanionCPUInput.Request? {
        guard wantsHostCPU else { return nil }
        return input.beginRequest()
    }

    public func acceptCPU(
        _ request: CompanionCPUInput.Request, id: UUID, epoch: UUID,
        capturedAt: ContinuousClock.Instant, hostPercentage: Double
    ) {
        guard wantsHostCPU, input.accept(request, id: id, epoch: epoch,
            capturedAt: capturedAt, hostPercentage: hostPercentage) else { return }
        reconcile()
    }

    public func cpuUnavailable(_ request: CompanionCPUInput.Request) {
        guard input.unavailable(request) else { return }
        reconcile()
    }

    /// Called by the host when replacing a lease without changing presentation.
    public func invalidateCPU() {
        input.invalidateSession()
        reconcile()
    }

    private func reconcile() {
        let now = elapsed()
        localIngress.advance(to: now, arbitration: &arbitration)
        if active && localEventsEnabled {
            if localEventSession == nil { localEventSession = UUID() }
        } else if localEventSession != nil {
            localEventSession = nil
            localIngress.revokeLocalState(at: now, arbitration: &arbitration)
        }
        input.setMode(active && !reduceMotion ? preferredMode : .disabled)
        if let reaction = input.reaction {
            arbitration.submit(reaction.state, from: .cpu, at: now)
        } else {
            arbitration.clear(.cpu, at: now)
        }
        scheduleDeadline(active ? arbitration.nextDeadline : nil, at: now)
        if active, let catalog {
            renderer.setReduceMotion(reduceMotion)
            renderer.setRate(input.rate)
            renderer.install(catalog.asset(for: arbitration.state))
        } else {
            renderer.stop()
        }
        if lastPublishedState != state || lastPublishedRate != rate {
            lastPublishedState = state
            lastPublishedRate = rate
            onStateChange?(state, rate)
        }
    }

    /// One-shot expiry, independent of CPU polling. Reconcile the current
    /// arbitration value, not a captured channel or an outdated deadline.
    private func scheduleDeadline(_ next: Duration?, at now: Duration) {
        guard scheduledDeadline != next else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        scheduledDeadline = next
        deadlineGeneration = UUID()
        guard let next else { return }
        let generation = deadlineGeneration
        deadlineTask = deadlineScheduler(max(.zero, next - now)) { [weak self] in
            guard let self, self.deadlineGeneration == generation else { return }
            self.deadlineGeneration = UUID()
            self.scheduledDeadline = nil
            self.deadlineTask = nil
            self.reconcile()
        }
    }
}
