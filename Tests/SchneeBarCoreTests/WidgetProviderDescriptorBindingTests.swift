import Foundation
import SchneeBarCore
import Testing

private final class DescriptorBindingProvider: @unchecked Sendable, WidgetProvider {
    private var currentDescriptor: WidgetDescriptor
    private var snapshotDescriptor: WidgetDescriptor
    private var snapshotText: String

    init(
        descriptor: WidgetDescriptor,
        snapshotDescriptor: WidgetDescriptor? = nil,
        text: String = "value"
    ) {
        currentDescriptor = descriptor
        self.snapshotDescriptor = snapshotDescriptor ?? descriptor
        snapshotText = text
    }

    var descriptor: WidgetDescriptor {
        currentDescriptor
    }

    func snapshot() async throws -> WidgetSnapshot {
        let descriptor = snapshotDescriptor
        let text = snapshotText

        return WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 42),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(text: text, accessibilityLabel: text),
                normal: .init(text: text, accessibilityLabel: text)
            )
        )
    }

    func updateDescriptor(_ descriptor: WidgetDescriptor) {
        currentDescriptor = descriptor
    }

    func updateSnapshot(
        descriptor: WidgetDescriptor,
        text: String
    ) {
        snapshotDescriptor = descriptor
        snapshotText = text
    }
}

private final class ChangingDescriptorReadProvider:
    @unchecked Sendable,
    WidgetProvider
{
    private let first: WidgetDescriptor
    private let later: WidgetDescriptor
    private var reads = 0

    init(
        first: WidgetDescriptor,
        later: WidgetDescriptor
    ) {
        self.first = first
        self.later = later
    }

    var descriptor: WidgetDescriptor {
        defer { reads += 1 }
        return reads == 0 ? first : later
    }

    func snapshot() async throws -> WidgetSnapshot {
        WidgetSnapshot(
            descriptor: first,
            generatedAt: Date(timeIntervalSince1970: 7),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(text: "first", accessibilityLabel: "first"),
                normal: .init(text: "first", accessibilityLabel: "first")
            )
        )
    }

    func descriptorReadCount() -> Int {
        reads
    }
}

private func boundDescriptor(
    displayName: String = "Bound",
    visibility: WidgetVisibilityPolicy = .always,
    refresh: WidgetRefreshPolicy = .interval(30)
) -> WidgetDescriptor {
    WidgetDescriptor(
        id: "bound.widget",
        displayName: displayName,
        visibilityPolicy: visibility,
        refreshPolicy: refresh
    )
}

@Test
func bootstrapCapturesProviderDescriptorExactlyOnce() async {
    let first = boundDescriptor(displayName: "First")
    let later = WidgetDescriptor(
        id: "other.widget",
        displayName: "Later"
    )
    let provider = ChangingDescriptorReadProvider(
        first: first,
        later: later
    )

    let engine = WidgetEngine(providers: [provider])

    #expect(provider.descriptorReadCount() == 1)
    #expect(await engine.descriptors() == [first])

    _ = await engine.refresh(id: first.id)

    #expect(provider.descriptorReadCount() == 1)
    #expect(await engine.snapshot(id: first.id)?.descriptor == first)
}

@Test
func dynamicRegistrationCapturesProviderDescriptorExactlyOnce() async throws {
    let first = boundDescriptor(displayName: "First")
    let later = WidgetDescriptor(
        id: "other.widget",
        displayName: "Later"
    )
    let provider = ChangingDescriptorReadProvider(
        first: first,
        later: later
    )
    let engine = WidgetEngine()

    try await engine.register(provider)

    #expect(provider.descriptorReadCount() == 1)
    #expect(await engine.descriptors() == [first])
}

@Test
func groupReplacementCapturesEachProviderDescriptorExactlyOnce() async throws {
    let first = WidgetDescriptor(
        id: "external.first",
        displayName: "First"
    )
    let later = WidgetDescriptor(
        id: "invalid/provider",
        displayName: "Later"
    )
    let provider = ChangingDescriptorReadProvider(
        first: first,
        later: later
    )
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: WidgetProviderGroupID(rawValue: "external.widgets"),
        with: [provider]
    )

    #expect(provider.descriptorReadCount() == 1)
    #expect(await engine.descriptors() == [first])
}

@Test
func engineKeepsRegisteredDescriptorWhenProviderDescriptorDrifts() async {
    let registered = boundDescriptor()
    let provider = DescriptorBindingProvider(descriptor: registered)
    let engine = WidgetEngine(providers: [provider])

    provider.updateDescriptor(
        boundDescriptor(
            displayName: "Changed",
            visibility: .whenNotNominal,
            refresh: .interval(1)
        )
    )

    #expect(await engine.descriptors() == [registered])
    let attemptedAt = Date(timeIntervalSince1970: 10_000)
    #expect(
        await engine.secondsUntilNextRefresh(at: attemptedAt) == 0
    )

    _ = await engine.refresh(
        id: registered.id,
        at: attemptedAt
    )

    #expect(
        await engine.secondsUntilNextRefresh(at: attemptedAt)
            == 30
    )
}

@Test
func mismatchedSnapshotDescriptorIsRejectedAsProviderFailure() async throws {
    let registered = boundDescriptor()
    let mismatched = WidgetDescriptor(
        id: "other.widget",
        displayName: "Spoofed",
        refreshPolicy: .manual
    )
    let provider = DescriptorBindingProvider(
        descriptor: registered,
        snapshotDescriptor: mismatched
    )
    let engine = WidgetEngine(providers: [provider])
    let attemptedAt = Date(timeIntervalSince1970: 100)

    let snapshot = await engine.refresh(
        id: registered.id,
        at: attemptedAt
    )

    #expect(snapshot == nil)

    let diagnostic = try #require(
        await engine.diagnostic(id: registered.id)
    )
    #expect(diagnostic.descriptor == registered)
    #expect(diagnostic.health == .unavailable)
    #expect(diagnostic.lastAttemptedAt == attemptedAt)
    #expect(diagnostic.lastSucceededAt == nil)
    #expect(diagnostic.lastFailureAt == attemptedAt)
    #expect(diagnostic.consecutiveFailureCount == 1)
}

@Test
func sameIDButDifferentDescriptorMetadataIsRejected() async throws {
    let registered = boundDescriptor()
    let mismatched = boundDescriptor(
        displayName: "Spoofed",
        visibility: .minimumSeverity(.critical),
        refresh: .manual
    )
    let provider = DescriptorBindingProvider(
        descriptor: registered,
        snapshotDescriptor: mismatched
    )
    let engine = WidgetEngine(providers: [provider])

    _ = await engine.refresh(id: registered.id)

    let diagnostic = try #require(
        await engine.diagnostic(id: registered.id)
    )
    #expect(diagnostic.health == .unavailable)
    #expect(await engine.snapshot(id: registered.id) == nil)
}

@Test
func mismatchedSnapshotPreservesLastKnownGood() async throws {
    let registered = boundDescriptor()
    let provider = DescriptorBindingProvider(
        descriptor: registered,
        text: "good"
    )
    let engine = WidgetEngine(providers: [provider])
    let first = Date(timeIntervalSince1970: 200)
    let second = Date(timeIntervalSince1970: 210)

    let good = try #require(
        await engine.refresh(id: registered.id, at: first)
    )

    provider.updateSnapshot(
        descriptor: WidgetDescriptor(
            id: "other.widget",
            displayName: "Other"
        ),
        text: "spoofed"
    )

    let afterMismatch = await engine.refresh(
        id: registered.id,
        at: second
    )

    #expect(afterMismatch == good)
    #expect(afterMismatch?.content().text == "good")

    let diagnostic = try #require(
        await engine.diagnostic(id: registered.id)
    )
    #expect(diagnostic.health == .degraded)
    #expect(diagnostic.lastSucceededAt == first)
    #expect(diagnostic.lastFailureAt == second)
    #expect(diagnostic.consecutiveFailureCount == 1)
    #expect(diagnostic.isServingLastKnownGood)
}

@Test
func groupReplacementBindsReplacementDescriptorAndClearsOldState() async throws {
    let id: WidgetID = "external.bound"
    let firstDescriptor = WidgetDescriptor(
        id: id,
        displayName: "First",
        refreshPolicy: .manual
    )
    let replacementDescriptor = WidgetDescriptor(
        id: id,
        displayName: "Replacement",
        visibilityPolicy: .whenNotNominal,
        refreshPolicy: .manual
    )
    let engine = WidgetEngine()
    let groupID = WidgetProviderGroupID(
        rawValue: "external.widgets"
    )

    try await engine.replaceProviders(
        in: groupID,
        with: [
            DescriptorBindingProvider(
                descriptor: firstDescriptor,
                text: "first"
            ),
        ]
    )
    _ = await engine.refresh(id: id)

    try await engine.replaceProviders(
        in: groupID,
        with: [
            DescriptorBindingProvider(
                descriptor: replacementDescriptor,
                text: "replacement"
            ),
        ]
    )

    #expect(await engine.descriptors() == [replacementDescriptor])
    #expect(await engine.snapshot(id: id) == nil)

    let refreshed = try #require(await engine.refresh(id: id))
    #expect(refreshed.descriptor == replacementDescriptor)
    #expect(refreshed.content().text == "replacement")
}

@Test
func reregistrationBindsReplacementDescriptorAndClearsOldState() async throws {
    let firstDescriptor = boundDescriptor(displayName: "First")
    let firstProvider = DescriptorBindingProvider(
        descriptor: firstDescriptor,
        text: "first"
    )
    let engine = WidgetEngine(providers: [firstProvider])

    _ = await engine.refresh(id: firstDescriptor.id)

    let replacementDescriptor = boundDescriptor(
        displayName: "Replacement",
        refresh: .manual
    )
    let replacement = DescriptorBindingProvider(
        descriptor: replacementDescriptor,
        text: "replacement"
    )

    try await engine.register(replacement)

    #expect(await engine.descriptors() == [replacementDescriptor])
    #expect(await engine.snapshot(id: replacementDescriptor.id) == nil)

    let refreshed = try #require(
        await engine.refresh(id: replacementDescriptor.id)
    )
    #expect(refreshed.descriptor == replacementDescriptor)
    #expect(refreshed.content().text == "replacement")
}
