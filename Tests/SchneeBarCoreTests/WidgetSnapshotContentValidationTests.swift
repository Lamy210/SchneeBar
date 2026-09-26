import Foundation
@testable import SchneeBarCore
import Testing

private actor SnapshotContentProvider: WidgetProvider {
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
            throw SnapshotContentTestError.exhausted
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

private enum SnapshotContentTestError: Error {
    case exhausted
}

@Test
func snapshotContentRejectsEmptyPaddedAndControlBearingText() async throws {
    let descriptor = snapshotContentDescriptor()
    let invalidContents: [WidgetContent] = [
        .init(text: "", accessibilityLabel: "Valid"),
        .init(text: "   ", accessibilityLabel: "Valid"),
        .init(text: " padded", accessibilityLabel: "Valid"),
        .init(text: "padded ", accessibilityLabel: "Valid"),
        .init(text: "line\nbreak", accessibilityLabel: "Valid"),
        .init(text: "nul\0value", accessibilityLabel: "Valid"),
    ]

    for content in invalidContents {
        let snapshot = makeSnapshot(
            descriptor: descriptor,
            compact: content
        )
        let engine = WidgetEngine(
            providers: [
                SnapshotContentProvider(
                    descriptor: descriptor,
                    snapshots: [snapshot]
                ),
            ]
        )

        #expect(
            await engine.refresh(
                id: descriptor.id,
                at: Date(timeIntervalSince1970: 1_000)
            ) == nil
        )

        let diagnostic = try #require(
            await engine.diagnostic(id: descriptor.id)
        )
        #expect(diagnostic.health == .unavailable)
        #expect(diagnostic.consecutiveFailureCount == 1)
    }
}

@Test
func snapshotContentRejectsInvalidAccessibilityLabels() async throws {
    let descriptor = snapshotContentDescriptor()
    let invalidLabels = [
        "",
        " ",
        " leading",
        "trailing ",
        "line\nbreak",
        "nul\0value",
    ]

    for label in invalidLabels {
        let snapshot = makeSnapshot(
            descriptor: descriptor,
            compact: .init(
                text: "OK",
                accessibilityLabel: label
            )
        )
        let engine = WidgetEngine(
            providers: [
                SnapshotContentProvider(
                    descriptor: descriptor,
                    snapshots: [snapshot]
                ),
            ]
        )

        _ = await engine.refresh(id: descriptor.id)

        #expect(await engine.snapshot(id: descriptor.id) == nil)
        #expect(
            await engine.diagnostic(id: descriptor.id)?.health
                == .unavailable
        )
    }
}

@Test
func snapshotContentAppliesBoundsToEveryRepresentation() async throws {
    let descriptor = snapshotContentDescriptor()

    let compactTooLong = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: String(repeating: "a", count: 33),
            accessibilityLabel: "Compact"
        )
    )
    let normalTooLong = makeSnapshot(
        descriptor: descriptor,
        normal: .init(
            text: String(repeating: "b", count: 129),
            accessibilityLabel: "Normal"
        )
    )
    let criticalTooLong = makeSnapshot(
        descriptor: descriptor,
        critical: .init(
            text: String(repeating: "c", count: 129),
            accessibilityLabel: "Critical"
        )
    )

    for snapshot in [
        compactTooLong,
        normalTooLong,
        criticalTooLong,
    ] {
        let engine = WidgetEngine(
            providers: [
                SnapshotContentProvider(
                    descriptor: descriptor,
                    snapshots: [snapshot]
                ),
            ]
        )
        _ = await engine.refresh(id: descriptor.id)
        #expect(await engine.snapshot(id: descriptor.id) == nil)
    }
}

@Test
func snapshotContentEnforcesIndependentUTF8ByteBounds() async {
    let descriptor = snapshotContentDescriptor()

    let compact = WidgetContent(
        text: String(repeating: "👨‍👩‍👧‍👦", count: 8),
        accessibilityLabel: "Compact"
    )
    #expect(compact.text.count <= 32)
    #expect(compact.text.utf8.count > 128)

    let normal = WidgetContent(
        text: String(repeating: "👨‍👩‍👧‍👦", count: 24),
        accessibilityLabel: "Normal"
    )
    #expect(normal.text.count <= 128)
    #expect(normal.text.utf8.count > 512)

    let accessibility = WidgetContent(
        text: "OK",
        accessibilityLabel: String(
            repeating: "👨‍👩‍👧‍👦",
            count: 30
        )
    )
    #expect(accessibility.accessibilityLabel.count <= 160)
    #expect(accessibility.accessibilityLabel.utf8.count > 640)

    for snapshot in [
        makeSnapshot(descriptor: descriptor, compact: compact),
        makeSnapshot(descriptor: descriptor, normal: normal),
        makeSnapshot(
            descriptor: descriptor,
            compact: accessibility
        ),
    ] {
        let engine = WidgetEngine(
            providers: [
                SnapshotContentProvider(
                    descriptor: descriptor,
                    snapshots: [snapshot]
                ),
            ]
        )
        _ = await engine.refresh(id: descriptor.id)
        #expect(await engine.snapshot(id: descriptor.id) == nil)
    }
}

@Test
func snapshotContentAcceptsBoundedUnicodeAndMissingSystemImage() async throws {
    let descriptor = snapshotContentDescriptor()
    let snapshot = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: "正常 ✅",
            accessibilityLabel: "ビルドは正常です"
        ),
        normal: .init(
            text: "デプロイ完了 🚀",
            accessibilityLabel: "デプロイが完了しました"
        ),
        critical: .init(
            text: "復旧済み",
            accessibilityLabel: "障害は復旧済みです"
        )
    )
    let engine = WidgetEngine(
        providers: [
            SnapshotContentProvider(
                descriptor: descriptor,
                snapshots: [snapshot]
            ),
        ]
    )

    let loaded = await engine.refresh(id: descriptor.id)

    #expect(loaded == snapshot)
    #expect(await engine.snapshot(id: descriptor.id) == snapshot)
    #expect(
        await engine.diagnostic(id: descriptor.id)?.health
            == .healthy
    )
}

@Test
func snapshotContentValidatesSystemImageWithoutNativeAllowlist() async {
    let descriptor = snapshotContentDescriptor()

    let control = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: "OK",
            systemImage: "hammer\n",
            accessibilityLabel: "Build okay"
        )
    )
    let oversized = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: "OK",
            systemImage: String(repeating: "a", count: 65),
            accessibilityLabel: "Build okay"
        )
    )

    for snapshot in [control, oversized] {
        let engine = WidgetEngine(
            providers: [
                SnapshotContentProvider(
                    descriptor: descriptor,
                    snapshots: [snapshot]
                ),
            ]
        )
        _ = await engine.refresh(id: descriptor.id)
        #expect(await engine.snapshot(id: descriptor.id) == nil)
    }

    let customNativeSymbol = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: "OK",
            systemImage: "person.crop.circle.badge.questionmark",
            accessibilityLabel: "Build okay"
        )
    )
    let engine = WidgetEngine(
        providers: [
            SnapshotContentProvider(
                descriptor: descriptor,
                snapshots: [customNativeSymbol]
            ),
        ]
    )

    #expect(
        await engine.refresh(id: descriptor.id)
            == customNativeSymbol
    )
}

@Test
func invalidSnapshotContentPreservesLastKnownGoodAndDegradesHealth() async throws {
    let descriptor = snapshotContentDescriptor()
    let good = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: "Good",
            accessibilityLabel: "Good"
        )
    )
    let invalid = makeSnapshot(
        descriptor: descriptor,
        normal: .init(
            text: " bad",
            accessibilityLabel: "Invalid"
        )
    )
    let provider = SnapshotContentProvider(
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
}

@Test
func cancellationWinsBeforeSnapshotContentValidation() async throws {
    let descriptor = snapshotContentDescriptor()
    let invalid = makeSnapshot(
        descriptor: descriptor,
        compact: .init(
            text: "",
            accessibilityLabel: ""
        )
    )
    let engine = WidgetEngine(
        providers: [
            SnapshotContentProvider(
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
}


@Test
func snapshotContentRejectsInvalidTextAcrossEveryRepresentation() async {
    let descriptor = snapshotContentDescriptor()
    let commonInvalidValues = [
        "",
        " leading",
        "trailing ",
        "line\nbreak",
        "nul\0value",
    ]

    for kind in WidgetRepresentationKind.allCases {
        let maximumCharacters = kind == .compact ? 32 : 128
        let byteHeavyCount = kind == .compact ? 8 : 24
        let invalidValues = commonInvalidValues + [
            String(repeating: "a", count: maximumCharacters + 1),
            String(
                repeating: "👨‍👩‍👧‍👦",
                count: byteHeavyCount
            ),
        ]

        for value in invalidValues {
            let content = WidgetContent(
                text: value,
                accessibilityLabel: "Valid label"
            )
            let snapshot = makeSnapshot(
                descriptor: descriptor,
                replacing: kind,
                with: content
            )
            let engine = WidgetEngine(
                providers: [
                    SnapshotContentProvider(
                        descriptor: descriptor,
                        snapshots: [snapshot]
                    ),
                ]
            )

            _ = await engine.refresh(id: descriptor.id)
            #expect(await engine.snapshot(id: descriptor.id) == nil)
        }
    }
}

@Test
func snapshotContentRejectsInvalidAccessibilityAcrossEveryRepresentation() async {
    let descriptor = snapshotContentDescriptor()
    let invalidLabels = [
        "",
        " leading",
        "trailing ",
        "line\nbreak",
        "nul\0value",
        String(repeating: "a", count: 161),
        String(repeating: "👨‍👩‍👧‍👦", count: 30),
    ]

    for kind in WidgetRepresentationKind.allCases {
        for label in invalidLabels {
            let content = WidgetContent(
                text: "OK",
                accessibilityLabel: label
            )
            let snapshot = makeSnapshot(
                descriptor: descriptor,
                replacing: kind,
                with: content
            )
            let engine = WidgetEngine(
                providers: [
                    SnapshotContentProvider(
                        descriptor: descriptor,
                        snapshots: [snapshot]
                    ),
                ]
            )

            _ = await engine.refresh(id: descriptor.id)
            #expect(await engine.snapshot(id: descriptor.id) == nil)
        }
    }
}

@Test
func snapshotContentRejectsInvalidSystemImageAcrossEveryRepresentation() async {
    let descriptor = snapshotContentDescriptor()
    let invalidSystemImages = [
        "hammer\n",
        "nul\0symbol",
        String(repeating: "a", count: 65),
    ]

    for kind in WidgetRepresentationKind.allCases {
        for systemImage in invalidSystemImages {
            let content = WidgetContent(
                text: "OK",
                systemImage: systemImage,
                accessibilityLabel: "Valid label"
            )
            let snapshot = makeSnapshot(
                descriptor: descriptor,
                replacing: kind,
                with: content
            )
            let engine = WidgetEngine(
                providers: [
                    SnapshotContentProvider(
                        descriptor: descriptor,
                        snapshots: [snapshot]
                    ),
                ]
            )

            _ = await engine.refresh(id: descriptor.id)
            #expect(await engine.snapshot(id: descriptor.id) == nil)
        }
    }
}

@Test
func descriptorMismatchRemainsRejectedWhenSnapshotContentIsAlsoInvalid() async throws {
    let descriptor = snapshotContentDescriptor()
    let mismatchedDescriptor = WidgetDescriptor(
        id: descriptor.id,
        displayName: "Different Descriptor"
    )
    let invalid = makeSnapshot(
        descriptor: mismatchedDescriptor,
        compact: .init(
            text: "",
            accessibilityLabel: ""
        )
    )
    let attemptedAt = Date(timeIntervalSince1970: 3_100)
    let engine = WidgetEngine(
        providers: [
            SnapshotContentProvider(
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
    #expect(diagnostic.lastFailureAt == attemptedAt)
    #expect(diagnostic.consecutiveFailureCount == 1)
}

private func snapshotContentDescriptor() -> WidgetDescriptor {
    WidgetDescriptor(
        id: "provider.snapshot_content",
        displayName: "Snapshot Content"
    )
}


private func makeSnapshot(
    descriptor: WidgetDescriptor,
    replacing kind: WidgetRepresentationKind,
    with content: WidgetContent
) -> WidgetSnapshot {
    switch kind {
    case .compact:
        return makeSnapshot(
            descriptor: descriptor,
            compact: content
        )
    case .normal:
        return makeSnapshot(
            descriptor: descriptor,
            normal: content
        )
    case .critical:
        return makeSnapshot(
            descriptor: descriptor,
            critical: content
        )
    }
}

private func makeSnapshot(
    descriptor: WidgetDescriptor,
    compact: WidgetContent = .init(
        text: "OK",
        systemImage: "checkmark.circle",
        accessibilityLabel: "Compact okay"
    ),
    normal: WidgetContent = .init(
        text: "Everything is okay",
        systemImage: "custom.native.symbol",
        accessibilityLabel: "Normal okay"
    ),
    critical: WidgetContent? = nil
) -> WidgetSnapshot {
    WidgetSnapshot(
        descriptor: descriptor,
        generatedAt: Date(timeIntervalSince1970: 100),
        severity: .nominal,
        priority: .normal,
        representations: .init(
            compact: compact,
            normal: normal,
            critical: critical
        )
    )
}
