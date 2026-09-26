import Foundation
import SchneeBarCore
import Testing

private struct RefreshPolicyValidationProvider: WidgetProvider {
    let descriptor: WidgetDescriptor
    private let text: String

    init(
        id: WidgetID,
        refreshPolicy: WidgetRefreshPolicy,
        text: String = "value"
    ) {
        descriptor = WidgetDescriptor(
            id: id,
            displayName: "Refresh Policy Validation",
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
    Double.nan,
    Double.infinity,
    -Double.infinity,
])
func singleRegistrationRejectsNonFiniteInterval(
    interval: Double
) async throws {
    let existingID: WidgetID = "system.clock"
    let engine = WidgetEngine(
        providers: [
            RefreshPolicyValidationProvider(
                id: existingID,
                refreshPolicy: .manual,
                text: "existing"
            ),
        ]
    )
    _ = await engine.refresh(id: existingID)

    await #expect(
        throws: WidgetProviderRegistrationError.invalidRefreshPolicy
    ) {
        try await engine.register(
            RefreshPolicyValidationProvider(
                id: "provider.invalid",
                refreshPolicy: .interval(interval)
            )
        )
    }

    #expect(await engine.descriptors().map(\.id) == [existingID])
    #expect(
        await engine.snapshot(id: existingID)?.content().text
            == "existing"
    )
}

@Test(arguments: [
    (Double.nan, 30.0),
    (30.0, Double.nan),
    (Double.infinity, 30.0),
    (30.0, Double.infinity),
    (-Double.infinity, 30.0),
    (30.0, -Double.infinity),
])
func singleRegistrationRejectsNonFiniteAdaptiveIntervals(
    active: Double,
    idle: Double
) async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderRegistrationError.invalidRefreshPolicy
    ) {
        try await engine.register(
            RefreshPolicyValidationProvider(
                id: "provider.invalid",
                refreshPolicy: .adaptive(
                    active: active,
                    idle: idle
                )
            )
        )
    }

    #expect(await engine.descriptors().isEmpty)
}

@Test
func groupReplacementRejectsNonFiniteRefreshPolicyAtomically() async throws {
    let groupID = WidgetProviderGroupID(rawValue: "external.widgets")
    let existingID: WidgetID = "external.acme.build"
    let engine = WidgetEngine()

    try await engine.replaceProviders(
        in: groupID,
        with: [
            RefreshPolicyValidationProvider(
                id: existingID,
                refreshPolicy: .manual,
                text: "existing"
            ),
        ]
    )
    _ = await engine.refresh(id: existingID)

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidRefreshPolicy
    ) {
        try await engine.replaceProviders(
            in: groupID,
            with: [
                RefreshPolicyValidationProvider(
                    id: "external.team.deploy",
                    refreshPolicy: .interval(.nan),
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
func providerIDValidationPrecedesRefreshPolicyValidation() async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderRegistrationError.invalidProviderID
    ) {
        try await engine.register(
            RefreshPolicyValidationProvider(
                id: "invalid/provider",
                refreshPolicy: .interval(.nan)
            )
        )
    }

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidProviderID
    ) {
        try await engine.replaceProviders(
            in: WidgetProviderGroupID(rawValue: "external.widgets"),
            with: [
                RefreshPolicyValidationProvider(
                    id: "invalid/provider",
                    refreshPolicy: .interval(.nan)
                ),
            ]
        )
    }
}

@Test
func providerGroupValidationPrecedesRefreshPolicyValidation() async {
    let engine = WidgetEngine()

    await #expect(
        throws: WidgetProviderBatchUpdateError.invalidProviderGroupID
    ) {
        try await engine.replaceProviders(
            in: WidgetProviderGroupID(rawValue: "invalid/group"),
            with: [
                RefreshPolicyValidationProvider(
                    id: "provider.valid",
                    refreshPolicy: .interval(.nan)
                ),
            ]
        )
    }

    #expect(await engine.descriptors().isEmpty)
}

@Test
func finiteZeroAndNegativeIntervalsRetainOneSecondFloor() async throws {
    let zeroID: WidgetID = "provider.zero"
    let negativeID: WidgetID = "provider.negative"
    let engine = WidgetEngine()

    try await engine.register(
        RefreshPolicyValidationProvider(
            id: zeroID,
            refreshPolicy: .interval(0)
        )
    )
    try await engine.register(
        RefreshPolicyValidationProvider(
            id: negativeID,
            refreshPolicy: .adaptive(
                active: 0,
                idle: -2
            )
        )
    )

    #expect(
        await engine.descriptors().map(\.id)
            == [negativeID, zeroID]
    )
    #expect(
        WidgetRefreshPolicy.interval(0)
            .interval(for: .nominal) == 1
    )
    #expect(
        WidgetRefreshPolicy.adaptive(active: 0, idle: -2)
            .interval(for: .active) == 1
    )
    #expect(
        WidgetRefreshPolicy.adaptive(active: 0, idle: -2)
            .interval(for: .nominal) == 1
    )
}

@Test
func cancellationWinsBeforeNonFiniteRefreshPolicyValidation() async throws {
    let engine = WidgetEngine()

    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        try await engine.register(
            RefreshPolicyValidationProvider(
                id: "provider.cancelled",
                refreshPolicy: .interval(.nan)
            )
        )
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(await engine.descriptors().isEmpty)
}
