import Foundation
import SchneeBarCore
import Testing

private let externalWidgetGroup = WidgetProviderGroupID(
    rawValue: "external.widgets"
)

private let secondaryWidgetGroup = WidgetProviderGroupID(
    rawValue: "secondary.widgets"
)

private struct BatchWidgetProvider: WidgetProvider {
    let descriptor: WidgetDescriptor
    let text: String

    init(id: WidgetID, text: String) {
        descriptor = WidgetDescriptor(
            id: id,
            displayName: id.rawValue,
            refreshPolicy: .manual
        )
        self.text = text
    }

    func snapshot() async throws -> WidgetSnapshot {
        WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 123),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(
                    text: text,
                    accessibilityLabel: text
                ),
                normal: .init(
                    text: text,
                    accessibilityLabel: text
                )
            )
        )
    }
}

private actor InFlightBatchWidgetProvider: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "external.acme.build",
        displayName: "External Build",
        refreshPolicy: .manual
    )

    private var started = false
    private var continuation: CheckedContinuation<WidgetSnapshot, Never>?

    func snapshot() async throws -> WidgetSnapshot {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func finish() {
        continuation?.resume(
            returning: WidgetSnapshot(
                descriptor: descriptor,
                generatedAt: Date(timeIntervalSince1970: 111),
                severity: .nominal,
                priority: .normal,
                representations: .init(
                    compact: .init(
                        text: "old",
                        accessibilityLabel: "old"
                    ),
                    normal: .init(
                        text: "old",
                        accessibilityLabel: "old"
                    )
                )
            )
        )
        continuation = nil
    }
}

@Test
func groupReplacementAtomicallyReplacesOnlyGroupOwnedProviders() async throws {
    let nativeID: WidgetID = "system.clock"
    let oldExternalID: WidgetID = "external.acme.build"
    let removedExternalID: WidgetID = "external.legacy.build"
    let newExternalID: WidgetID = "external.team.deploy"

    let engine = WidgetEngine(providers: [
        BatchWidgetProvider(id: nativeID, text: "native"),
    ])
    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: oldExternalID, text: "old"),
            BatchWidgetProvider(id: removedExternalID, text: "legacy"),
        ]
    )

    _ = await engine.refresh(id: nativeID)
    _ = await engine.refresh(id: oldExternalID)

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: oldExternalID, text: "new"),
            BatchWidgetProvider(id: newExternalID, text: "deploy"),
        ]
    )

    #expect(
        await engine.descriptors().map(\.id)
            == [oldExternalID, newExternalID, nativeID]
    )
    #expect(await engine.snapshot(id: nativeID)?.content().text == "native")
    #expect(await engine.snapshot(id: oldExternalID) == nil)
    #expect(await engine.snapshot(id: removedExternalID) == nil)
    #expect(await engine.snapshot(id: newExternalID) == nil)

    _ = await engine.refresh(id: oldExternalID)
    _ = await engine.refresh(id: newExternalID)

    #expect(await engine.snapshot(id: oldExternalID)?.content().text == "new")
    #expect(await engine.snapshot(id: newExternalID)?.content().text == "deploy")
}

@Test
func replacingOneProviderGroupPreservesAnotherGroupAndItsRuntimeState() async throws {
    let externalID: WidgetID = "external.acme.build"
    let secondaryID: WidgetID = "secondary.status"

    let engine = WidgetEngine()
    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: externalID, text: "external-old"),
        ]
    )
    try await engine.replaceProviders(
        in: secondaryWidgetGroup,
        with: [
            BatchWidgetProvider(id: secondaryID, text: "secondary"),
        ]
    )

    _ = await engine.refresh(id: secondaryID)
    let before = try #require(
        await engine.diagnostic(id: secondaryID)
    )

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: externalID, text: "external-new"),
        ]
    )

    let secondarySnapshot = try #require(
        await engine.snapshot(id: secondaryID)
    )
    let after = try #require(
        await engine.diagnostic(id: secondaryID)
    )

    #expect(secondarySnapshot.content().text == "secondary")
    #expect(after == before)

    _ = await engine.refresh(id: externalID)
    #expect(
        await engine.snapshot(id: externalID)?.content().text
            == "external-new"
    )
}

@Test
func groupReplacementRejectsNativeCollisionWithoutPartialMutation() async throws {
    let nativeID: WidgetID = "system.clock"
    let externalID: WidgetID = "external.acme.build"
    let engine = WidgetEngine(providers: [
        BatchWidgetProvider(id: nativeID, text: "native"),
    ])
    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: externalID, text: "external"),
        ]
    )

    _ = await engine.refresh(id: nativeID)
    _ = await engine.refresh(id: externalID)

    await #expect(
        throws: WidgetProviderBatchUpdateError
            .providerAlreadyRegistered(nativeID)
    ) {
        try await engine.replaceProviders(
            in: externalWidgetGroup,
            with: [
                BatchWidgetProvider(id: nativeID, text: "collision"),
            ]
        )
    }

    #expect(
        await engine.descriptors().map(\.id)
            == [externalID, nativeID]
    )
    #expect(await engine.snapshot(id: nativeID)?.content().text == "native")
    #expect(await engine.snapshot(id: externalID)?.content().text == "external")
}

@Test
func groupReplacementRejectsDuplicateReplacementIDsWithoutPartialMutation() async throws {
    let externalID: WidgetID = "external.acme.build"
    let engine = WidgetEngine()
    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: externalID, text: "old"),
        ]
    )

    _ = await engine.refresh(id: externalID)

    await #expect(
        throws: WidgetProviderBatchUpdateError
            .duplicateProviderID(externalID)
    ) {
        try await engine.replaceProviders(
            in: externalWidgetGroup,
            with: [
                BatchWidgetProvider(id: externalID, text: "first"),
                BatchWidgetProvider(id: externalID, text: "second"),
            ]
        )
    }

    #expect(await engine.snapshot(id: externalID)?.content().text == "old")
    #expect(await engine.descriptors().map(\.id) == [externalID])
}

@Test
func groupReplacementInvalidatesInFlightRemovedProviderRefresh() async throws {
    let id: WidgetID = "external.acme.build"
    let oldProvider = InFlightBatchWidgetProvider()
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [oldProvider]
    )

    let oldRefresh = Task {
        await engine.refresh(id: id)
    }

    while !(await oldProvider.hasStarted()) {
        await Task.yield()
    }

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: id, text: "new"),
        ]
    )

    await oldProvider.finish()
    _ = await oldRefresh.value

    #expect(await engine.snapshot(id: id) == nil)

    _ = await engine.refresh(id: id)
    #expect(await engine.snapshot(id: id)?.content().text == "new")
}

@Test
func unregisteringGroupOwnedProviderClearsOwnershipBeforeAnotherGroupClaimsID() async throws {
    let id: WidgetID = "external.acme.build"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: id, text: "first-group"),
        ]
    )

    await engine.unregister(id: id)

    try await engine.replaceProviders(
        in: secondaryWidgetGroup,
        with: [
            BatchWidgetProvider(id: id, text: "second-group"),
        ]
    )

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: []
    )

    #expect(await engine.descriptors().map(\.id) == [id])

    _ = await engine.refresh(id: id)
    #expect(
        await engine.snapshot(id: id)?.content().text
            == "second-group"
    )
}

@Test
func singleProviderRegistrationTransfersOwnershipOutOfGroup() async throws {
    let id: WidgetID = "external.acme.build"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: id, text: "group-owned"),
        ]
    )

    await engine.register(
        BatchWidgetProvider(id: id, text: "independent")
    )
    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: []
    )

    #expect(await engine.descriptors().map(\.id) == [id])

    _ = await engine.refresh(id: id)
    #expect(
        await engine.snapshot(id: id)?.content().text
            == "independent"
    )
}


@Test
func cancelledGroupReplacementLeavesExistingProvidersUntouched() async throws {
    let id: WidgetID = "external.acme.build"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: externalWidgetGroup,
        with: [
            BatchWidgetProvider(id: id, text: "old"),
        ]
    )
    _ = await engine.refresh(id: id)

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        try await engine.replaceProviders(
            in: externalWidgetGroup,
            with: [
                BatchWidgetProvider(id: id, text: "new"),
            ]
        )
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(await engine.snapshot(id: id)?.content().text == "old")
    #expect(await engine.descriptors().map(\.id) == [id])
}
