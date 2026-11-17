import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore

/// Single-surface composition seam. Owns no AppKit status item, CPU timer,
/// filesystem permission, or persistence. The host owns demand reconciliation.
@MainActor
public final class CompanionRuntimeCoordinator {
    private let renderer: CompanionMenuBarRenderer
    private var catalog: CompanionAssetCatalog?
    private var input = CompanionCPUInput()
    private var arbitration = CompanionArbitration()
    private let origin = ContinuousClock.now
    private var preferredMode: CompanionCPUInput.Mode = .automatic
    private var enabled = false
    private var visible = false
    private var awake = true
    private var reduceMotion = false

    public init(renderer: CompanionMenuBarRenderer) {
        self.renderer = renderer
    }

    private var active: Bool { enabled && visible && awake && catalog != nil }
    private var elapsed: Duration { origin.duration(to: .now) }

    /// Consume this flag from the application's existing scheduler only.
    public var wantsHostCPU: Bool {
        active && !reduceMotion && preferredMode == .automatic
    }

    public var state: CompanionState { arbitration.state }
    public var rate: CompanionPlaybackRate { input.rate }
    public var displayedFrameIndex: Int? { renderer.displayedFrameIndex }

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
            arbitration.submit(state, from: .manual, at: elapsed)
        } else {
            arbitration.clear(.manual, at: elapsed)
        }
        reconcile()
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
        input.setMode(active && !reduceMotion ? preferredMode : .disabled)
        if let reaction = input.reaction {
            arbitration.submit(reaction.state, from: .cpu, at: elapsed)
        } else {
            arbitration.clear(.cpu, at: elapsed)
        }
        guard active, let catalog else {
            renderer.stop()
            return
        }

        renderer.setReduceMotion(reduceMotion)
        renderer.setRate(input.rate)
        renderer.install(catalog.asset(for: arbitration.state))
    }
}
