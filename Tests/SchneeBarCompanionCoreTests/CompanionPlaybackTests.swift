import Foundation
import SchneeBarCompanionCore
import Testing

@Test func clipTimingBounds() throws {
    #expect(throws: CompanionClipError.invalidCount) {
        try CompanionClip(revision: UUID(), durations: [])
    }
    #expect(throws: CompanionClipError.invalidCount) {
        try CompanionClip(revision: UUID(), durations: Array(repeating: 0.1, count: 121))
    }
    for invalid in [Double.nan, .infinity, 0, 0.019, 10.01] {
        #expect(throws: CompanionClipError.invalidDuration) {
            try CompanionClip(revision: UUID(), durations: [invalid])
        }
    }
    #expect(try CompanionClip(revision: UUID(), durations: [0.02]).durations.count == 1)
    #expect(try CompanionClip(revision: UUID(), durations: Array(repeating: 10, count: 120)).durations.count == 120)
}

@Test func rateFactorsPreserveAuthoredTiming() throws {
    let clip = try CompanionClip(revision: UUID(), durations: [0.04, 0.12, 0.08])
    #expect(CompanionPlaybackRate.twoThirds.factor == 8.0 / 12)
    for rate in CompanionPlaybackRate.allCases {
        let first = try #require(clip.delay(at: 0, rate: rate))
        let second = try #require(clip.delay(at: 1, rate: rate))
        let third = try #require(clip.delay(at: 2, rate: rate))
        #expect(abs(second / first - 3) < 0.000001)
        #expect(abs(third / first - 2) < 0.000001)
        #expect(abs(first * rate.factor - 0.04) < 0.000001)
    }
    #expect(clip.delay(at: -1, rate: .normal) == nil)
    #expect(clip.delay(at: 3, rate: .normal) == nil)
}

@Test func catalogExactFallbackAndConflictingRevision() throws {
    let run = try CompanionClip(revision: UUID(), durations: [0.1])
    let idle = try CompanionClip(revision: UUID(), durations: [0.2])
    let catalog = try CompanionClipCatalog(clips: [.run: run, .idle: idle], defaultState: .run)
    #expect(catalog.clip(for: .idle) == idle)
    #expect(catalog.clip(for: .dash) == run)
    #expect(throws: CompanionClipError.missingDefault) {
        try CompanionClipCatalog(clips: [.idle: idle], defaultState: .run)
    }
    let conflict = try CompanionClip(revision: run.revision, durations: [0.3])
    #expect(throws: CompanionClipError.conflictingRevision) {
        try CompanionClipCatalog(clips: [.run: run, .idle: conflict], defaultState: .run)
    }
}

@Test func cursorContinuityRateChangeAndSingleUseTick() throws {
    let clip = try CompanionClip(revision: UUID(), durations: [0.1, 0.2])
    var cursor = CompanionPlaybackCursor()
    #expect((cursor.select(clip)) == true)
    let first = try #require(cursor.nextTick)
    #expect((cursor.tick(first.token)) == true)
    #expect(cursor.frameIndex == 1)
    #expect((cursor.tick(first.token)) == false)
    let pending = try #require(cursor.nextTick)
    #expect((cursor.select(clip)) == false)
    #expect(cursor.nextTick == pending)
    #expect((cursor.setRate(.double)) == true)
    #expect(cursor.frameIndex == 1)
    #expect((cursor.tick(pending.token)) == false)
    let faster = try #require(cursor.nextTick)
    #expect(faster.delay == 0.1)
    #expect((cursor.tick(faster.token)) == true)
    #expect(cursor.frameIndex == 0)
}

@Test func cursorReplacementClearAndStaticClip() throws {
    let a = try CompanionClip(revision: UUID(), durations: [0.1, 0.2])
    let b = try CompanionClip(revision: UUID(), durations: [0.1, 0.2])
    let still = try CompanionClip(revision: UUID(), durations: [0.2])
    var cursor = CompanionPlaybackCursor()
    #expect((cursor.select(a)) == true)
    let old = try #require(cursor.nextTick)
    #expect((cursor.select(b)) == true)
    #expect((cursor.tick(old.token)) == false)
    #expect(cursor.frameIndex == 0)
    let pending = try #require(cursor.nextTick)
    #expect((cursor.select(still)) == true)
    #expect(cursor.nextTick == nil)
    #expect((cursor.tick(pending.token)) == false)
    #expect((cursor.select(nil)) == true)
    #expect(cursor.nextTick == nil)
}
