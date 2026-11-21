import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore

/// Isolated AppKit frame driver. The caller is responsible for owning a single
/// status item and disabling the driver before discarding its presentation.
@MainActor
public final class CompanionMenuBarRenderer {
    private var cursor = CompanionPlaybackCursor()
    private var asset: CompanionDecodedClip?
    private var pending: Task<Void, Never>?
    private var scheduleID = UUID()
    private var reduceMotion = false
    private let onFrame: @MainActor (NSImage) -> Void
    private let onClear: @MainActor () -> Void
    typealias Scheduler = @MainActor (Double, @escaping @MainActor () -> Void) -> Task<Void, Never>
    private let scheduler: Scheduler

    public convenience init(
        onFrame: @escaping @MainActor (NSImage) -> Void,
        onClear: @escaping @MainActor () -> Void
    ) {
        self.init(onFrame: onFrame, onClear: onClear, scheduler: { delay, callback in
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                callback()
            }
        })
    }

    /// Internal deterministic scheduling seam. The scheduler must enqueue,
    /// never invoke the callback synchronously before returning.
    init(
        onFrame: @escaping @MainActor (NSImage) -> Void,
        onClear: @escaping @MainActor () -> Void,
        scheduler: @escaping Scheduler
    ) {
        self.onFrame = onFrame
        self.onClear = onClear
        self.scheduler = scheduler
    }

    deinit { pending?.cancel() }

    public var displayedFrameIndex: Int? { asset == nil ? nil : cursor.frameIndex }

    public func install(_ next: CompanionDecodedClip) {
        guard cursor.select(next.clip) else { return }
        asset = next
        cancelTick()
        emitCurrentFrame()
        scheduleNext()
    }

    public func setRate(_ rate: CompanionPlaybackRate) {
        guard cursor.setRate(rate) else { return }
        scheduleNext()
    }

    /// Freeze current frame while keeping the surrounding text/status usable.
    public func setReduceMotion(_ enabled: Bool) {
        guard reduceMotion != enabled else { return }
        reduceMotion = enabled
        scheduleNext()
    }

    public func stop() {
        let hadAsset = asset != nil
        cancelTick()
        _ = cursor.select(nil)
        asset = nil
        if hadAsset { onClear() }
    }

    private func cancelTick() {
        pending?.cancel()
        pending = nil
        scheduleID = UUID()
    }

    private func emitCurrentFrame() {
        guard let asset, asset.frames.indices.contains(cursor.frameIndex) else { return }
        let frame = asset.frames[cursor.frameIndex]
        let scale = 18.0 / Double(max(frame.width, frame.height))
        let size = NSSize(width: Double(frame.width) * scale, height: Double(frame.height) * scale)
        let image = NSImage(cgImage: frame, size: size)
        image.isTemplate = false
        onFrame(image)
    }

    private func scheduleNext() {
        cancelTick()
        guard !reduceMotion, let tick = cursor.nextTick else { return }
        let expected = scheduleID
        pending = scheduler(tick.delay) { [weak self] in
            guard let self, self.scheduleID == expected,
                  !self.reduceMotion, self.cursor.tick(tick.token) else { return }
            self.pending = nil
            self.emitCurrentFrame()
            self.scheduleNext()
        }
    }
}
