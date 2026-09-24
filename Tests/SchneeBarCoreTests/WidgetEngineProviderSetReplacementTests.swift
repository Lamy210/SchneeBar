import Foundation
import SchneeBarCore
import Testing

private struct ProviderSetStub: WidgetProvider {
    let descriptor: WidgetDescriptor
    let text: String

    init(
        id: WidgetID,
        displayName: String,
        text: String
    ) {
        descriptor = WidgetDescriptor(
            id: id,
            displayName: displayName,
            refreshPolicy: .manual
        )
        self.text = text
    }

    func snapshot() async throws -> WidgetSnapshot {
        makeProviderSetSnapshot(
            descriptor: descriptor,
            text: text
        )
    }
}

private actor BlockingProviderSetStub: WidgetProvider {
    nonisolated let descriptor = WidgetDescriptor(
        id: "owned",
        displayName: "Owned Old",
        refreshPolicy: .manual
    )

    private var didStart = false
    private var continuation: CheckedContinuation<WidgetSnapshot, Never>?

    func snapshot() async throws -> WidgetSnapshot {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        didStart
    }

    func finish() {
        continuation?.resume(
            returning: makeProviderSetSnapshot(
                descriptor: descriptor,
                text: "old"
            )
        )
        continuation = nil
    }
}

@Test
func providerSetReplacementRejectsDuplicateReplacementIDsWithoutMutation() async throws {
    let native = ProviderSetStub(
        id: "native",
        displayName: "Native",
        text: "native"
    )
    let owned = ProviderSetStub(
        id: "owned",
        displayName: "Owned",
        text: "owned"
    )
    let engine = WidgetEngine(providers: [native, owned])

    await #expect(
        throws: WidgetEngineProviderSetError
            .duplicateReplacementID("replacement")
    ) {
        try await engine.replaceProviders(
            removing: ["owned"],
            with: [
                ProviderSetStub(
                    id: "replacement",
                    displayName: "First",
                    text: "first"
                ),
                ProviderSetStub(
                    id: "replacement",
                    displayName: "Second",
                    text: "second"
                ),
            ]
        )
    }

    #expect(
        await engine.descriptors().map(\.id.rawValue)
            == ["native", "owned"]
    )
}

@Test
func providerSetReplacementRejectsCollisionOutsideOwnedSetWithoutMutation() async throws {
    let native = ProviderSetStub(
        id: "native",
        displayName: "Native",
        text: "native"
    )
    let owned = ProviderSetStub(
        id: "owned",
        displayName: "Owned",
        text: "owned"
    )
    let engine = WidgetEngine(providers: [native, owned])

    await #expect(
        throws: WidgetEngineProviderSetError
            .conflictingProviderID("native")
    ) {
        try await engine.replaceProviders(
            removing: ["owned"],
            with: [
                ProviderSetStub(
                    id: "native",
                    displayName: "Shadow",
                    text: "shadow"
                ),
            ]
        )
    }

    let descriptors = await engine.descriptors()
    #expect(descriptors.map(\.id.rawValue) == ["native", "owned"])
    #expect(
        descriptors.first(where: { $0.id == "native" })?.displayName
            == "Native"
    )
}

@Test
func providerSetReplacementAtomicallyRemovesStaleAndInstallsNewProviders() async throws {
    let engine = WidgetEngine(providers: [
        ProviderSetStub(
            id: "native",
            displayName: "Native",
            text: "native"
        ),
        ProviderSetStub(
            id: "owned-a",
            displayName: "Owned A Old",
            text: "old-a"
        ),
        ProviderSetStub(
            id: "owned-b",
            displayName: "Owned B",
            text: "old-b"
        ),
    ])

    try await engine.replaceProviders(
        removing: ["owned-a", "owned-b"],
        with: [
            ProviderSetStub(
                id: "owned-a",
                displayName: "Owned A New",
                text: "new-a"
            ),
            ProviderSetStub(
                id: "owned-c",
                displayName: "Owned C",
                text: "new-c"
            ),
        ]
    )

    let descriptors = await engine.descriptors()
    #expect(
        descriptors.map(\.id.rawValue)
            == ["native", "owned-a", "owned-c"]
    )
    #expect(
        descriptors.first(where: { $0.id == "owned-a" })?.displayName
            == "Owned A New"
    )
}

@Test
func providerSetReplacementPreservesUnrelatedRuntimeStateAndResetsAffectedIDs() async throws {
    let native = ProviderSetStub(
        id: "native",
        displayName: "Native",
        text: "native"
    )
    let owned = ProviderSetStub(
        id: "owned",
        displayName: "Owned Old",
        text: "old"
    )
    let engine = WidgetEngine(providers: [native, owned])

    _ = await engine.refresh(
        id: "native",
        at: Date(timeIntervalSince1970: 100)
    )
    _ = await engine.refresh(
        id: "owned",
        at: Date(timeIntervalSince1970: 200)
    )

    try await engine.replaceProviders(
        removing: ["owned"],
        with: [
            ProviderSetStub(
                id: "owned",
                displayName: "Owned New",
                text: "new"
            ),
        ]
    )

    let nativeSnapshot = try #require(
        await engine.snapshot(id: "native")
    )
    let nativeDiagnostic = try #require(
        await engine.diagnostic(id: "native")
    )
    let ownedDiagnostic = try #require(
        await engine.diagnostic(id: "owned")
    )

    #expect(nativeSnapshot.content().text == "native")
    #expect(nativeDiagnostic.health == .healthy)
    #expect(
        nativeDiagnostic.lastSucceededAt
            == Date(timeIntervalSince1970: 100)
    )

    #expect(await engine.snapshot(id: "owned") == nil)
    #expect(ownedDiagnostic.health == .notLoaded)
    #expect(ownedDiagnostic.lastAttemptedAt == nil)
}

@Test
func emptyProviderSetReplacementRemovesOnlyCallerOwnedIDs() async throws {
    let engine = WidgetEngine(providers: [
        ProviderSetStub(
            id: "native",
            displayName: "Native",
            text: "native"
        ),
        ProviderSetStub(
            id: "owned",
            displayName: "Owned",
            text: "owned"
        ),
    ])

    try await engine.replaceProviders(
        removing: ["owned"],
        with: []
    )

    #expect(
        await engine.descriptors().map(\.id.rawValue)
            == ["native"]
    )
}

@Test
func inFlightRefreshFromReplacedProviderCannotOverwriteNewProviderSnapshot() async throws {
    let oldProvider = BlockingProviderSetStub()
    let engine = WidgetEngine(providers: [oldProvider])

    let oldRefresh = Task {
        await engine.refresh(
            id: "owned",
            at: Date(timeIntervalSince1970: 300)
        )
    }

    while !(await oldProvider.hasStarted()) {
        await Task.yield()
    }

    try await engine.replaceProviders(
        removing: ["owned"],
        with: [
            ProviderSetStub(
                id: "owned",
                displayName: "Owned New",
                text: "new"
            ),
        ]
    )

    _ = await engine.refresh(
        id: "owned",
        at: Date(timeIntervalSince1970: 400)
    )

    await oldProvider.finish()
    _ = await oldRefresh.value

    let snapshot = try #require(
        await engine.snapshot(id: "owned")
    )
    let diagnostic = try #require(
        await engine.diagnostic(id: "owned")
    )

    #expect(snapshot.content().text == "new")
    #expect(
        diagnostic.lastSucceededAt
            == Date(timeIntervalSince1970: 400)
    )
}

private func makeProviderSetSnapshot(
    descriptor: WidgetDescriptor,
    text: String
) -> WidgetSnapshot {
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
