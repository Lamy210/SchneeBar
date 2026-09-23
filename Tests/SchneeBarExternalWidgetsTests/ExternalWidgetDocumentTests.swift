import Foundation
import SchneeBarCore
@testable import SchneeBarExternalWidgets
import Testing

@Test
func decodesAndNormalizesVersionOneDocument() throws {
    let data = Data(
        #"""
        {
          "schemaVersion": 1,
          "id": "external.acme.build",
          "displayName": "Acme Build",
          "defaultEnabled": false,
          "defaultOrder": 1200,
          "defaultRepresentation": "normal",
          "visibility": {
            "kind": "minimumSeverity",
            "minimumSeverity": "attention"
          },
          "refresh": {
            "kind": "adaptive",
            "activeSeconds": 15,
            "idleSeconds": 300
          },
          "snapshot": {
            "severity": "attention",
            "priority": "attention",
            "generatedAtUnixSeconds": 1800000000,
            "compact": {
              "text": "!1",
              "systemImage": "exclamationmark.triangle.fill",
              "accessibilityLabel": "One build needs attention"
            },
            "normal": {
              "text": "Build needs attention",
              "systemImage": "hammer",
              "accessibilityLabel": "Acme build needs attention"
            },
            "critical": {
              "text": "Build failed",
              "systemImage": "xmark.circle.fill",
              "accessibilityLabel": "Acme build failed"
            }
          }
        }
        """#.utf8
    )
    let document = try JSONDecoder().decode(
        ExternalWidgetDocument.self,
        from: data
    )

    let definition = try ExternalWidgetDocumentAdapter().normalize(
        document,
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )

    #expect(definition.descriptor.id == "external.acme.build")
    #expect(definition.descriptor.displayName == "Acme Build")
    #expect(!definition.descriptor.defaultIsEnabled)
    #expect(definition.descriptor.defaultOrder == 1200)
    #expect(definition.descriptor.defaultRepresentation == .normal)
    #expect(
        definition.descriptor.visibilityPolicy
            == .minimumSeverity(.attention)
    )
    #expect(
        definition.descriptor.refreshPolicy
            == .adaptive(active: 15, idle: 300)
    )
    #expect(
        definition.snapshot.generatedAt
            == Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(definition.snapshot.severity == .attention)
    #expect(definition.snapshot.priority == .attention)
    #expect(
        definition.snapshot.representations.compact.systemImage
            == "exclamationmark.triangle.fill"
    )
    #expect(
        definition.snapshot.representations.critical?.text
            == "Build failed"
    )
}

@Test
func rejectsUnknownDocumentKeysInsteadOfSilentlyIgnoringCapabilities() throws {
    let topLevel = Data(
        #"""
        {
          "schemaVersion": 1,
          "id": "external.acme.build",
          "displayName": "Acme Build",
          "defaultEnabled": false,
          "defaultOrder": 1200,
          "defaultRepresentation": "normal",
          "visibility": {"kind": "always"},
          "refresh": {"kind": "manual"},
          "snapshot": {
            "severity": "nominal",
            "priority": "normal",
            "compact": {
              "text": "OK",
              "accessibilityLabel": "Build okay"
            },
            "normal": {
              "text": "Build okay",
              "accessibilityLabel": "Build okay"
            }
          },
          "command": "/bin/sh"
        }
        """#.utf8
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ExternalWidgetDocument.self,
            from: topLevel
        )
    }

    let nested = Data(
        #"""
        {
          "schemaVersion": 1,
          "id": "external.acme.build",
          "displayName": "Acme Build",
          "defaultEnabled": false,
          "defaultOrder": 1200,
          "defaultRepresentation": "normal",
          "visibility": {"kind": "always"},
          "refresh": {"kind": "manual"},
          "snapshot": {
            "severity": "nominal",
            "priority": "normal",
            "url": "https://example.invalid/status",
            "compact": {
              "text": "OK",
              "accessibilityLabel": "Build okay"
            },
            "normal": {
              "text": "Build okay",
              "accessibilityLabel": "Build okay"
            }
          }
        }
        """#.utf8
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ExternalWidgetDocument.self,
            from: nested
        )
    }
}

@Test
func rejectsUnsupportedSchemaVersion() {
    let document = externalWidgetDocument(schemaVersion: 2)

    #expect(
        throws: ExternalWidgetDocumentError
            .unsupportedSchemaVersion(2)
    ) {
        try ExternalWidgetDocumentAdapter().normalize(document)
    }
}

@Test(arguments: [
    "system.cpu",
    "external.",
    "external..build",
    "external.Acme.build",
    "external.acme/build",
    "external.acme-build",
])
func rejectsUnsafeOrNonReservedIdentifiers(id: String) {
    let document = externalWidgetDocument(id: id)

    #expect(throws: ExternalWidgetDocumentError.invalidID) {
        try ExternalWidgetDocumentAdapter().normalize(document)
    }
}

@Test
func externalWidgetCannotSelfEnableOrPreemptNativeDefaultOrdering() {
    #expect(
        throws: ExternalWidgetDocumentError.defaultEnablementNotAllowed
    ) {
        try ExternalWidgetDocumentAdapter().normalize(
            externalWidgetDocument(defaultEnabled: true)
        )
    }

    for order in [999, 10_001] {
        #expect(throws: ExternalWidgetDocumentError.invalidDefaultOrder) {
            try ExternalWidgetDocumentAdapter().normalize(
                externalWidgetDocument(defaultOrder: order)
            )
        }
    }
}

@Test
func externalWidgetCannotDefaultToCriticalRepresentation() {
    #expect(
        throws: ExternalWidgetDocumentError.invalidDefaultRepresentation
    ) {
        try ExternalWidgetDocumentAdapter().normalize(
            externalWidgetDocument(defaultRepresentation: .critical)
        )
    }
}

@Test
func visibilityPolicyRejectsMissingOrExtraneousParameters() {
    let adapter = ExternalWidgetDocumentAdapter()

    #expect(
        throws: ExternalWidgetDocumentError.invalidVisibilityPolicy
    ) {
        try adapter.normalize(
            externalWidgetDocument(
                visibility: ExternalWidgetVisibilityDocument(
                    kind: .minimumSeverity
                )
            )
        )
    }

    #expect(
        throws: ExternalWidgetDocumentError.invalidVisibilityPolicy
    ) {
        try adapter.normalize(
            externalWidgetDocument(
                visibility: ExternalWidgetVisibilityDocument(
                    kind: .always,
                    minimumSeverity: .attention
                )
            )
        )
    }
}

@Test
func refreshPolicyRejectsFieldsThatDoNotBelongToSelectedKind() {
    let adapter = ExternalWidgetDocumentAdapter()

    #expect(throws: ExternalWidgetDocumentError.invalidRefreshPolicy) {
        try adapter.normalize(
            externalWidgetDocument(
                refresh: ExternalWidgetRefreshDocument(
                    kind: .manual,
                    intervalSeconds: 30
                )
            )
        )
    }

    #expect(throws: ExternalWidgetDocumentError.invalidRefreshPolicy) {
        try adapter.normalize(
            externalWidgetDocument(
                refresh: ExternalWidgetRefreshDocument(
                    kind: .interval,
                    intervalSeconds: 30,
                    activeSeconds: 10
                )
            )
        )
    }
}

@Test
func refreshPolicyIsBoundedAndAdaptivePolicyMustBeCoherent() {
    let adapter = ExternalWidgetDocumentAdapter()

    for seconds in [4.0, 3601.0, .infinity] {
        #expect(throws: ExternalWidgetDocumentError.invalidRefreshPolicy) {
            try adapter.normalize(
                externalWidgetDocument(
                    refresh: ExternalWidgetRefreshDocument(
                        kind: .interval,
                        intervalSeconds: seconds
                    )
                )
            )
        }
    }

    #expect(throws: ExternalWidgetDocumentError.invalidRefreshPolicy) {
        try adapter.normalize(
            externalWidgetDocument(
                refresh: ExternalWidgetRefreshDocument(
                    kind: .adaptive,
                    activeSeconds: 300,
                    idleSeconds: 30
                )
            )
        )
    }

    let manual = try? adapter.normalize(
        externalWidgetDocument(
            refresh: ExternalWidgetRefreshDocument(kind: .manual)
        )
    )
    #expect(manual?.descriptor.refreshPolicy == .manual)
}

@Test
func contentAndSystemImagesAreBounded() {
    let invalidControl = externalWidgetDocument(
        compact: ExternalWidgetContentDocument(
            text: "OK\nInjected",
            accessibilityLabel: "Build okay"
        )
    )
    #expect(
        throws: ExternalWidgetDocumentError.invalidContent(.compact)
    ) {
        try ExternalWidgetDocumentAdapter().normalize(invalidControl)
    }

    let unsupportedSymbol = externalWidgetDocument(
        compact: ExternalWidgetContentDocument(
            text: "OK",
            systemImage: "person.crop.circle.badge.questionmark",
            accessibilityLabel: "Build okay"
        )
    )
    #expect(
        throws: ExternalWidgetDocumentError.unsupportedSystemImage
    ) {
        try ExternalWidgetDocumentAdapter().normalize(unsupportedSymbol)
    }

    let oversized = externalWidgetDocument(
        normal: ExternalWidgetContentDocument(
            text: String(repeating: "a", count: 129),
            accessibilityLabel: "Build okay"
        )
    )
    #expect(
        throws: ExternalWidgetDocumentError.invalidContent(.normal)
    ) {
        try ExternalWidgetDocumentAdapter().normalize(oversized)
    }
}

@Test
func trailingControlCharactersAreRejectedBeforeWhitespaceNormalization() {
    let document = externalWidgetDocument(
        compact: ExternalWidgetContentDocument(
            text: "OK\n",
            accessibilityLabel: "Build okay"
        )
    )

    #expect(
        throws: ExternalWidgetDocumentError.invalidContent(.compact)
    ) {
        try ExternalWidgetDocumentAdapter().normalize(document)
    }
}

@Test
func documentRemainsCodableAfterStrictDecodingCustomization() throws {
    let original = externalWidgetDocument()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(
        ExternalWidgetDocument.self,
        from: data
    )

    #expect(decoded == original)
}

@Test
func collectionRejectsDuplicateIDsAndReturnsDeterministicOrder() throws {
    let adapter = ExternalWidgetDocumentAdapter()
    let alpha = externalWidgetDocument(id: "external.alpha.build")
    let beta = externalWidgetDocument(id: "external.beta.build")

    let normalized = try adapter.normalizeCollection([beta, alpha])
    #expect(
        normalized.map(\.descriptor.id.rawValue)
            == ["external.alpha.build", "external.beta.build"]
    )

    #expect(
        throws: ExternalWidgetDocumentError.duplicateID(
            WidgetID(rawValue: "external.alpha.build")
        )
    ) {
        try adapter.normalizeCollection([alpha, alpha])
    }
}

@Test
func duplicateIDPreflightWinsBeforeSecondDocumentContentValidation() {
    let first = externalWidgetDocument(id: "external.alpha.build")
    let invalidDuplicate = externalWidgetDocument(
        id: "external.alpha.build",
        compact: ExternalWidgetContentDocument(
            text: "OK",
            systemImage: "not.allowed",
            accessibilityLabel: "Build okay"
        )
    )

    #expect(
        throws: ExternalWidgetDocumentError.duplicateID(
            WidgetID(rawValue: "external.alpha.build")
        )
    ) {
        try ExternalWidgetDocumentAdapter().normalizeCollection(
            [first, invalidDuplicate]
        )
    }
}

@Test
func generatedAtDefaultsToNormalizationTimeAndRejectsUnreasonableValues() throws {
    let adapter = ExternalWidgetDocumentAdapter()
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    let definition = try adapter.normalize(
        externalWidgetDocument(generatedAtUnixSeconds: nil),
        now: now
    )
    #expect(definition.snapshot.generatedAt == now)

    for timestamp in [
        -1.0,
        now.timeIntervalSince1970 + 301,
        4_102_444_801.0,
        .infinity,
    ] {
        #expect(throws: ExternalWidgetDocumentError.invalidGeneratedAt) {
            try adapter.normalize(
                externalWidgetDocument(
                    generatedAtUnixSeconds: timestamp
                ),
                now: now
            )
        }
    }
}

@Test
func unknownEnumValueFailsDuringDecoding() {
    let data = Data(
        #"""
        {
          "schemaVersion": 1,
          "id": "external.acme.build",
          "displayName": "Acme Build",
          "defaultEnabled": false,
          "defaultOrder": 1200,
          "defaultRepresentation": "giant",
          "visibility": {"kind": "always"},
          "refresh": {"kind": "manual"},
          "snapshot": {
            "severity": "nominal",
            "priority": "normal",
            "compact": {
              "text": "OK",
              "accessibilityLabel": "Build okay"
            },
            "normal": {
              "text": "Build okay",
              "accessibilityLabel": "Build okay"
            }
          }
        }
        """#.utf8
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ExternalWidgetDocument.self,
            from: data
        )
    }
}

private func externalWidgetDocument(
    schemaVersion: Int = 1,
    id: String = "external.acme.build",
    defaultEnabled: Bool = false,
    defaultOrder: Int = 1200,
    defaultRepresentation: ExternalWidgetRepresentation = .normal,
    visibility: ExternalWidgetVisibilityDocument = .init(kind: .always),
    refresh: ExternalWidgetRefreshDocument = .init(kind: .manual),
    compact: ExternalWidgetContentDocument = .init(
        text: "OK",
        systemImage: "checkmark.circle.fill",
        accessibilityLabel: "Build okay"
    ),
    normal: ExternalWidgetContentDocument = .init(
        text: "Build okay",
        systemImage: "hammer",
        accessibilityLabel: "Build okay"
    ),
    generatedAtUnixSeconds: Double? = nil
) -> ExternalWidgetDocument {
    ExternalWidgetDocument(
        schemaVersion: schemaVersion,
        id: id,
        displayName: "Acme Build",
        defaultEnabled: defaultEnabled,
        defaultOrder: defaultOrder,
        defaultRepresentation: defaultRepresentation,
        visibility: visibility,
        refresh: refresh,
        snapshot: ExternalWidgetSnapshotDocument(
            severity: .nominal,
            priority: .normal,
            generatedAtUnixSeconds: generatedAtUnixSeconds,
            compact: compact,
            normal: normal
        )
    )
}
