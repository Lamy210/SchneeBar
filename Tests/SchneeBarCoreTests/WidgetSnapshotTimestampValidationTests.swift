import Foundation
import SchneeBarCore
import Testing

private actor SnapshotTimestampProvider: WidgetProvider {
    nonisolated let descriptor: WidgetDescriptor
    private var snapshots: [WidgetSnapshot]
    private let cancelBeforeReturn: Bool

    init(
        descriptor: WidgetDescriptor,
        snapshots: [WidgetSnapshot],
        cancelBeforeReturn: Bool = false
    ) {
        self.descriptor = descriptor
        self.snapshots = snapshots
        self.cancelBeforeReturn = cancelBeforeReturn
    }

    func snapshot() async throws -> WidgetSnapshot {
        guard !snapshots.isEmpty else {
            throw SnapshotTimestampTestError.exhausted
        }

        let snapshot = snapshots.removeFirst()
        if cancelBeforeReturn {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return snapshot
    }
}

private enum SnapshotTimestampTestError: Error {
    case exhausted
}

@Test(arguments: [
    Double.nan,
    Double.infinity,
    -Double.infinity,
])
func snapshotRejectsNonFiniteGeneratedAt(
    timeIntervalSinceReferenceDate: Double
) async throws {
    let descriptor = snapshotTimestampDescriptor()
    let invalid = makeTimestampSnapshot(
        descriptor: descriptor,
        timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate
    )
    let attemptedAt = Date(timeIntervalSince1970: 1_000)
    let engine = WidgetEngine(
        providers: [
            SnapshotTimestampProvider(
                descriptor: descriptor,
                snapshots: [invalid]
            ),
        ]
    )

    #expect(
        await engine.refresh(
            id: descriptor.id,
            at: attemptedAt
        ) == nil
    )
    #expect(await engine.snapshot(id: descriptor.id) == nil)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .unavailable)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastSucceededAt == nil)
    #expect(diagnostic.lastFailureAt == attemptedAt)
    #expect(diagnostic.consecutiveFailureCount == 1)
    #expect(diagnostic.snapshotGeneratedAt == nil)
}

@Test(arguments: [
    -1_000_000_000.0,
    0.0,
    10_000_000_000.0,
])
func snapshotAcceptsFiniteGeneratedAt(
    timeIntervalSinceReferenceDate: Double
) async throws {
    let descriptor = snapshotTimestampDescriptor()
    let snapshot = makeTimestampSnapshot(
        descriptor: descriptor,
        timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate
    )
    let engine = WidgetEngine(
        providers: [
            SnapshotTimestampProvider(
                descriptor: descriptor,
                snapshots: [snapshot]
            ),
        ]
    )

    #expect(await engine.refresh(id: descriptor.id) == snapshot)
    #expect(await engine.snapshot(id: descriptor.id) == snapshot)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .healthy)
    #expect(diagnostic.snapshotGeneratedAt == snapshot.generatedAt)
}

@Test
func invalidSnapshotTimestampPreservesLastKnownGood() async throws {
    let descriptor = snapshotTimestampDescriptor()
    let good = makeTimestampSnapshot(
        descriptor: descriptor,
        timeIntervalSinceReferenceDate: 100
    )
    let invalid = makeTimestampSnapshot(
        descriptor: descriptor,
        timeIntervalSinceReferenceDate: .nan
    )
    let provider = SnapshotTimestampProvider(
        descriptor: descriptor,
        snapshots: [good, invalid]
    )
    let engine = WidgetEngine(providers: [provider])
    let firstAttempt = Date(timeIntervalSince1970: 2_000)
    let secondAttempt = Date(timeIntervalSince1970: 2_100)

    #expect(
        await engine.refresh(
            id: descriptor.id,
            at: firstAttempt
        ) == good
    )
    #expect(
        await engine.refresh(
            id: descriptor.id,
            at: secondAttempt
        ) == good
    )

    #expect(await engine.snapshot(id: descriptor.id) == good)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .degraded)
    #expect(diagnostic.lastSucceededAt == firstAttempt)
    #expect(diagnostic.lastFailureAt == secondAttempt)
    #expect(diagnostic.consecutiveFailureCount == 1)
    #expect(diagnostic.isServingLastKnownGood)
    #expect(diagnostic.snapshotGeneratedAt == good.generatedAt)
}

@Test
func cancellationWinsBeforeSnapshotTimestampValidation() async throws {
    let descriptor = snapshotTimestampDescriptor()
    let invalid = makeTimestampSnapshot(
        descriptor: descriptor,
        timeIntervalSinceReferenceDate: .infinity
    )
    let engine = WidgetEngine(
        providers: [
            SnapshotTimestampProvider(
                descriptor: descriptor,
                snapshots: [invalid],
                cancelBeforeReturn: true
            ),
        ]
    )
    let attemptedAt = Date(timeIntervalSince1970: 3_000)

    let result = await Task {
        await engine.refresh(
            id: descriptor.id,
            at: attemptedAt
        )
    }.value

    #expect(result == nil)

    let diagnostic = try #require(
        await engine.diagnostic(id: descriptor.id)
    )
    #expect(diagnostic.health == .notLoaded)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastFailureAt == nil)
    #expect(diagnostic.consecutiveFailureCount == 0)
    #expect(diagnostic.snapshotGeneratedAt == nil)
}

private func snapshotTimestampDescriptor() -> WidgetDescriptor {
    WidgetDescriptor(
        id: "provider.snapshot_timestamp",
        displayName: "Snapshot Timestamp"
    )
}

private func makeTimestampSnapshot(
    descriptor: WidgetDescriptor,
    timeIntervalSinceReferenceDate: Double
) -> WidgetSnapshot {
    WidgetSnapshot(
        descriptor: descriptor,
        generatedAt: Date(
            timeIntervalSinceReferenceDate:
                timeIntervalSinceReferenceDate
        ),
        severity: .nominal,
        priority: .normal,
        representations: .init(
            compact: .init(
                text: "OK",
                accessibilityLabel: "Snapshot okay"
            ),
            normal: .init(
                text: "Snapshot is okay",
                accessibilityLabel: "Snapshot is okay"
            )
        )
    )
}
