import Foundation
import SchneeBarCore
import Testing

private struct DisplayNameValidationProvider: WidgetProvider {
    let descriptor: WidgetDescriptor
    private let text: String

    init(
        id: WidgetID,
        displayName: String,
        refreshPolicy: WidgetRefreshPolicy = .manual,
        text: String = "value"
    ) {
        descriptor = WidgetDescriptor(
            id: id,
            displayName: displayName,
            refreshPolicy: refreshPolicy
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

@Test(arguments: [
    "",
    " ",
    "  ",
    " Leading",
    "Trailing ",
    "\tTabbed",
    "Line\nBreak",
    "NUL\0Value",
    String(repeating: "a", count: 65),
    String(repeating: "雪", count: 86),
])
func singleRegistrationRejectsInvalidDisplayName(
    displayName: String
) async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderRegistrationError.invalidDisplayName
    ) {
        try await engine.register(
            DisplayNameValidationProvider(
                id: "provider.display",
                displayName: displayName
            )
        )
    }

    #expect(await engine.descriptors().isEmpty)
}

@Test(arguments: [
    "Provider Status",
    "Build 1",
    "開発状況",
    String(repeating: "a", count: 64),
    String(repeating: "雪", count: 64),
])
func singleRegistrationAcceptsCanonicalDisplayName(
    displayName: String
) async throws {
    let id: WidgetID = "provider.display"
    let engine = WidgetEngine()

    try await engine.register(
        DisplayNameValidationProvider(
            id: id,
            displayName: displayName
        )
    )

    #expect(
        await engine.descriptors().map(\.displayName)
            == [displayName]
    )
}

@Test
func groupReplacementRejectsInvalidDisplayNameAtomically() async throws {
    let groupID = WidgetProviderGroupID(rawValue: "external.widgets")
    let existingID: WidgetID = "external.acme.build"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: groupID,
        with: [
            DisplayNameValidationProvider(
                id: existingID,
                displayName: "Existing",
                text: "existing"
            ),
        ]
    )
    _ = await engine.refresh(id: existingID)

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidDisplayName
    ) {
        try await engine.replaceProviders(
            in: groupID,
            with: [
                DisplayNameValidationProvider(
                    id: "external.team.deploy",
                    displayName: " Invalid",
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
}

@Test
func providerIDValidationPrecedesDisplayNameValidation() async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderRegistrationError.invalidProviderID
    ) {
        try await engine.register(
            DisplayNameValidationProvider(
                id: "invalid/provider",
                displayName: ""
            )
        )
    }

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidProviderID
    ) {
        try await engine.replaceProviders(
            in: WidgetProviderGroupID(rawValue: "external.widgets"),
            with: [
                DisplayNameValidationProvider(
                    id: "invalid/provider",
                    displayName: ""
                ),
            ]
        )
    }
}

@Test
func displayNameValidationPrecedesRefreshPolicyValidation() async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderRegistrationError.invalidDisplayName
    ) {
        try await engine.register(
            DisplayNameValidationProvider(
                id: "provider.invalid",
                displayName: "",
                refreshPolicy: .interval(.nan)
            )
        )
    }

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidDisplayName
    ) {
        try await engine.replaceProviders(
            in: WidgetProviderGroupID(rawValue: "external.widgets"),
            with: [
                DisplayNameValidationProvider(
                    id: "provider.invalid",
                    displayName: "",
                    refreshPolicy: .interval(.nan)
                ),
            ]
        )
    }
}

@Test
func providerGroupValidationPrecedesDisplayNameValidation() async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidProviderGroupID
    ) {
        try await engine.replaceProviders(
            in: WidgetProviderGroupID(rawValue: "invalid/group"),
            with: [
                DisplayNameValidationProvider(
                    id: "provider.valid",
                    displayName: ""
                ),
            ]
        )
    }
}

@Test
func cancellationWinsBeforeDisplayNameValidation() async throws {
    let engine = WidgetEngine()

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        try await engine.register(
            DisplayNameValidationProvider(
                id: "provider.cancelled",
                displayName: ""
            )
        )
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(await engine.descriptors().isEmpty)
}
