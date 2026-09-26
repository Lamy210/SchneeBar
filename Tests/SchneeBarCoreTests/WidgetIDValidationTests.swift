import Foundation
import SchneeBarCore
import Testing

@Test(arguments: [
    "system.clock",
    "system.cpu",
    "developer.activity",
    "external.acme.build",
    "diagnostic-replacement",
    "widget_2",
])
func currentProviderWidgetIDsRemainValid(rawValue: String) {
    #expect(WidgetID(rawValue: rawValue).isValidProviderID)
}

@Test
func providerWidgetIDUsesBoundedCanonicalMachineSyntax() {
    #expect(
        WidgetID(
            rawValue: String(
                repeating: "a",
                count: WidgetID.maximumProviderUTF8Bytes
            )
        ).isValidProviderID
    )

    for rawValue in [
        "",
        "System.clock",
        " system.clock",
        "system.clock ",
        ".system.clock",
        "system.clock.",
        "system..clock",
        "-system.clock",
        "_system.clock",
        "system.-clock",
        "system._clock",
        "system.clock-",
        "system.clock_",
        "system/clock",
        "system\\clock",
        "system:clock",
        "system clock",
        "system\nclock",
        "system\0clock",
        String(
            repeating: "a",
            count: WidgetID.maximumProviderUTF8Bytes + 1
        ),
    ] {
        #expect(!WidgetID(rawValue: rawValue).isValidProviderID)
    }
}

@Test
func commonProviderIDRuleDoesNotReplaceStricterExternalNamespaceRule() {
    // The provider-neutral Core rule intentionally permits hyphens so existing
    // internal/test provider IDs remain valid. External-widget documents apply
    // their stricter external.* grammar before creating WidgetID values.
    #expect(
        WidgetID(rawValue: "external.acme-build")
            .isValidProviderID
    )
}


private struct WidgetIDValidationProvider: WidgetProvider {
    let descriptor: WidgetDescriptor
    private let text: String

    init(id: WidgetID, text: String = "value") {
        descriptor = WidgetDescriptor(
            id: id,
            displayName: "Validation",
            refreshPolicy: .manual
        )
        self.text = text
    }

    func snapshot() async throws -> WidgetSnapshot {
        WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 1),
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

@Test
func invalidSingleProviderRegistrationIsNonMutating() async throws {
    let existingID: WidgetID = "system.clock"
    let engine = WidgetEngine(
        providers: [
            WidgetIDValidationProvider(
                id: existingID,
                text: "existing"
            ),
        ]
    )
    _ = await engine.refresh(id: existingID)

    await #expect(
        throws: WidgetProviderRegistrationError.invalidProviderID
    ) {
        try await engine.register(
            WidgetIDValidationProvider(
                id: "invalid/provider",
                text: "replacement"
            )
        )
    }

    #expect(await engine.descriptors().map(\.id) == [existingID])
    #expect(
        await engine.snapshot(id: existingID)?.content().text
            == "existing"
    )
}

@Test
func cancelledSingleProviderRegistrationIsNonMutating() async throws {
    let existingID: WidgetID = "system.clock"
    let engine = WidgetEngine(
        providers: [WidgetIDValidationProvider(id: existingID)]
    )

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        try await engine.register(
            WidgetIDValidationProvider(id: "invalid/provider")
        )
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(await engine.descriptors().map(\.id) == [existingID])
}

@Test
func invalidGroupReplacementProviderIsNonMutating() async throws {
    let groupID = WidgetProviderGroupID(rawValue: "external.widgets")
    let existingID: WidgetID = "external.acme.build"
    let invalidID: WidgetID = "external/invalid"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: groupID,
        with: [
            WidgetIDValidationProvider(
                id: existingID,
                text: "existing"
            ),
        ]
    )
    _ = await engine.refresh(id: existingID)

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidProviderID
    ) {
        try await engine.replaceProviders(
            in: groupID,
            with: [
                WidgetIDValidationProvider(
                    id: invalidID,
                    text: "replacement"
                ),
            ]
        )
    }

    #expect(await engine.descriptors().map(\.id) == [existingID])
    #expect(
        await engine.snapshot(id: existingID)?.content().text
            == "existing"
    )
    #expect(await engine.snapshot(id: invalidID) == nil)
}

@Test
func invalidProviderIDWinsBeforeDuplicateAndCollisionChecks() async throws {
    let groupID = WidgetProviderGroupID(rawValue: "external.widgets")
    let nativeID: WidgetID = "system.clock"
    let invalidID: WidgetID = "invalid/provider"
    let engine = WidgetEngine(
        providers: [
            WidgetIDValidationProvider(id: nativeID),
        ]
    )

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidProviderID
    ) {
        try await engine.replaceProviders(
            in: groupID,
            with: [
                WidgetIDValidationProvider(id: invalidID),
                WidgetIDValidationProvider(id: invalidID),
                WidgetIDValidationProvider(id: nativeID),
            ]
        )
    }

    #expect(await engine.descriptors().map(\.id) == [nativeID])
}

@Test
func cancellationWinsBeforeInvalidProviderValidation() async throws {
    let groupID = WidgetProviderGroupID(rawValue: "external.widgets")
    let existingID: WidgetID = "external.acme.build"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: groupID,
        with: [WidgetIDValidationProvider(id: existingID)]
    )

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        try await engine.replaceProviders(
            in: groupID,
            with: [
                WidgetIDValidationProvider(id: "invalid/provider"),
            ]
        )
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(await engine.descriptors().map(\.id) == [existingID])
}
