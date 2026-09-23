import Foundation
import SchneeBarCore
import SchneeBarExternalWidgetProvider
import Testing

@Test
func normalizesValidDocumentIntoExistingWidgetModels() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let normalizer = ExternalWidgetDocumentNormalizer(now: { now })
    let document = externalWidgetDocument(
        id: "external.build_status",
        refresh: .init(kind: .interval, intervalSeconds: 60)
    )

    let definition = try normalizer.normalize(document)

    #expect(definition.descriptor.id == "external.build_status")
    #expect(definition.descriptor.displayName == "Build Status")
    #expect(!definition.descriptor.defaultIsEnabled)
    #expect(definition.descriptor.defaultOrder == 1_000)
    #expect(
        definition.descriptor.defaultRepresentation == .normal
    )
    #expect(
        definition.descriptor.visibilityPolicy == .whenNotNominal
    )
    #expect(
        definition.descriptor.refreshPolicy == .interval(60)
    )
    #expect(definition.snapshot.descriptor == definition.descriptor)
    #expect(definition.snapshot.generatedAt == now)
    #expect(definition.snapshot.severity == .attention)
    #expect(definition.snapshot.priority == .attention)
    #expect(
        definition.snapshot.content(for: .compact).text == "!1"
    )
    #expect(
        definition.snapshot.content(for: .normal).systemImage
            == "exclamationmark.triangle"
    )
}

@Test
func documentRoundTripsThroughJSONWithoutExecutableFields() throws {
    let document = externalWidgetDocument(
        id: "external.release",
        refresh: .init(kind: .manual)
    )
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(
        ExternalWidgetDocument.self,
        from: data
    )

    #expect(decoded == document)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("command"))
    #expect(!json.contains("script"))
    #expect(!json.contains("token"))
    #expect(!json.contains("secret"))
    #expect(!json.contains("url"))
}

@Test
func unknownSchemaEnumFailsDuringDecoding() throws {
    let json = """
    {
      "schemaVersion": 1,
      "id": "external.build",
      "displayName": "Build",
      "defaultOrder": 1000,
      "defaultRepresentation": "normal",
      "visibility": "always",
      "refresh": {"kind": "manual"},
      "snapshot": {
        "severity": "future-severity",
        "priority": "normal",
        "compact": {
          "text": "OK",
          "accessibilityLabel": "Build OK"
        },
        "normal": {
          "text": "Build OK",
          "accessibilityLabel": "Build OK"
        }
      }
    }
    """

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ExternalWidgetDocument.self,
            from: Data(json.utf8)
        )
    }
}

@Test(arguments: [
    0,
    2,
    999,
])
func rejectsUnsupportedSchemaVersions(_ version: Int) {
    let document = externalWidgetDocument(
        schemaVersion: version,
        id: "external.build"
    )

    #expect(
        throws:
            ExternalWidgetDocumentError.unsupportedSchemaVersion(
                version
            )
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(document)
    }
}

@Test(arguments: [
    "",
    "build",
    "external.",
    "external..build",
    "external.Build",
    "external.build/status",
    " external.build",
])
func rejectsInvalidExternalWidgetIDs(_ id: String) {
    let document = externalWidgetDocument(id: id)

    #expect(
        throws: ExternalWidgetDocumentError.invalidWidgetID(id)
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(document)
    }
}

@Test
func rejectsOversizedExternalWidgetID() {
    let id = "external." + String(repeating: "a", count: 121)
    #expect(id.count > ExternalWidgetDocumentNormalizer.maximumWidgetIDLength)

    #expect(
        throws: ExternalWidgetDocumentError.invalidWidgetID(id)
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(
            externalWidgetDocument(id: id)
        )
    }
}

@Test
func trimsDisplayAndContentButKeepsStrictBounds() throws {
    let normalizer = ExternalWidgetDocumentNormalizer(
        now: { Date(timeIntervalSince1970: 1_000) }
    )
    let document = ExternalWidgetDocument(
        id: "external.build",
        displayName: "  Build Status  ",
        snapshot: ExternalWidgetSnapshotDocument(
            severity: .nominal,
            priority: .normal,
            compact: .init(
                text: "  OK  ",
                accessibilityLabel: "  Build OK  "
            ),
            normal: .init(
                text: "  Build is healthy  ",
                accessibilityLabel: "  Build is healthy  "
            )
        )
    )

    let definition = try normalizer.normalize(document)

    #expect(definition.descriptor.displayName == "Build Status")
    #expect(definition.snapshot.content(for: .compact).text == "OK")
    #expect(
        definition.snapshot.content(for: .compact).accessibilityLabel
            == "Build OK"
    )
}

@Test
func rejectsBlankAndOversizedContent() {
    let blank = externalWidgetDocument(
        id: "external.blank",
        compact: .init(
            text: "  ",
            accessibilityLabel: "Blank"
        )
    )
    #expect(
        throws:
            ExternalWidgetDocumentError.invalidContent(
                field: "compact"
            )
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(blank)
    }

    let oversized = externalWidgetDocument(
        id: "external.long",
        compact: .init(
            text: String(
                repeating: "x",
                count: ExternalWidgetDocumentNormalizer
                    .maximumCompactTextLength + 1
            ),
            accessibilityLabel: "Long"
        )
    )
    #expect(
        throws:
            ExternalWidgetDocumentError.invalidContent(
                field: "compact"
            )
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(oversized)
    }
}

@Test
func acceptsOnlyAllowlistedSystemImages() throws {
    let allowed = externalWidgetDocument(
        id: "external.allowed",
        normal: .init(
            text: "Warning",
            systemImage: "exclamationmark.triangle",
            accessibilityLabel: "Warning"
        )
    )
    _ = try ExternalWidgetDocumentNormalizer().normalize(allowed)

    let denied = externalWidgetDocument(
        id: "external.denied",
        normal: .init(
            text: "Warning",
            systemImage: "person.crop.circle.badge.key",
            accessibilityLabel: "Warning"
        )
    )
    #expect(
        throws:
            ExternalWidgetDocumentError.unsupportedSystemImage(
                "person.crop.circle.badge.key"
            )
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(denied)
    }
}

@Test(arguments: [
    999,
    10_001,
])
func rejectsExternalDefaultOrderOutsideReservedRange(_ order: Int) {
    var document = externalWidgetDocument(id: "external.order")
    document = ExternalWidgetDocument(
        id: document.id,
        displayName: document.displayName,
        defaultOrder: order,
        defaultRepresentation: document.defaultRepresentation,
        visibility: document.visibility,
        refresh: document.refresh,
        snapshot: document.snapshot
    )

    #expect(
        throws: ExternalWidgetDocumentError.invalidDefaultOrder(order)
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(document)
    }
}

@Test
func rejectsCriticalAsTheDefaultExternalRepresentation() {
    let base = externalWidgetDocument(id: "external.critical-default")
    let document = ExternalWidgetDocument(
        id: base.id,
        displayName: base.displayName,
        defaultOrder: base.defaultOrder,
        defaultRepresentation: .critical,
        visibility: base.visibility,
        refresh: base.refresh,
        snapshot: base.snapshot
    )

    #expect(
        throws:
            ExternalWidgetDocumentError.invalidDefaultRepresentation
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(document)
    }
}

@Test
func rejectsControlCharactersInDisplayContent() {
    let document = externalWidgetDocument(
        id: "external.multiline",
        normal: .init(
            text: "Line 1\nLine 2",
            accessibilityLabel: "Multiline"
        )
    )

    #expect(
        throws:
            ExternalWidgetDocumentError.invalidContent(field: "normal")
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(document)
    }
}

@Test(arguments: [
    ExternalWidgetRefresh(
        kind: .manual,
        intervalSeconds: 60
    ),
    ExternalWidgetRefresh(
        kind: .interval,
        intervalSeconds: nil
    ),
    ExternalWidgetRefresh(
        kind: .interval,
        intervalSeconds: 1
    ),
    ExternalWidgetRefresh(
        kind: .interval,
        intervalSeconds: 90_000
    ),
    ExternalWidgetRefresh(
        kind: .interval,
        intervalSeconds: .infinity
    ),
])
func rejectsUnsafeRefreshPolicies(
    _ refresh: ExternalWidgetRefresh
) {
    let document = externalWidgetDocument(
        id: "external.refresh",
        refresh: refresh
    )

    #expect(
        throws: ExternalWidgetDocumentError.invalidRefreshPolicy
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(document)
    }
}

@Test
func rejectsInvalidAndExcessivelyFutureGeneratedAt() {
    let now = Date(timeIntervalSince1970: 1_000)
    let normalizer = ExternalWidgetDocumentNormalizer(now: { now })

    for seconds in [
        -1.0,
        Double.nan,
        Double.infinity,
        now.timeIntervalSince1970
            + ExternalWidgetDocumentNormalizer.maximumClockSkew + 1,
    ] {
        let document = externalWidgetDocument(
            id: "external.time",
            generatedAtEpochSeconds: seconds
        )
        #expect(
            throws: ExternalWidgetDocumentError.invalidGeneratedAt
        ) {
            try normalizer.normalize(document)
        }
    }
}

@Test
func duplicateDocumentsFailDeterministically() {
    let documents = [
        externalWidgetDocument(id: "external.same"),
        externalWidgetDocument(id: "external.same"),
    ]

    #expect(
        throws:
            ExternalWidgetDocumentError.duplicateWidgetID(
                "external.same"
            )
    ) {
        try ExternalWidgetDocumentNormalizer().normalize(documents)
    }
}

@Test
func collectionNormalizationSortsByStableWidgetID() throws {
    let documents = [
        externalWidgetDocument(id: "external.zeta"),
        externalWidgetDocument(id: "external.alpha"),
    ]

    let definitions = try ExternalWidgetDocumentNormalizer()
        .normalize(documents)

    #expect(
        definitions.map(\.descriptor.id.rawValue) == [
            "external.alpha",
            "external.zeta",
        ]
    )
}

private func externalWidgetDocument(
    schemaVersion: Int = 1,
    id: String,
    refresh: ExternalWidgetRefresh = .init(kind: .manual),
    generatedAtEpochSeconds: Double? = nil,
    compact: ExternalWidgetContentDocument = .init(
        text: "!1",
        accessibilityLabel: "Build needs attention"
    ),
    normal: ExternalWidgetContentDocument = .init(
        text: "Build needs attention",
        systemImage: "exclamationmark.triangle",
        accessibilityLabel: "Build needs attention"
    )
) -> ExternalWidgetDocument {
    ExternalWidgetDocument(
        schemaVersion: schemaVersion,
        id: id,
        displayName: "Build Status",
        defaultOrder: 1_000,
        defaultRepresentation: .normal,
        visibility: .whenNotNominal,
        refresh: refresh,
        snapshot: ExternalWidgetSnapshotDocument(
            generatedAtEpochSeconds: generatedAtEpochSeconds,
            severity: .attention,
            priority: .attention,
            compact: compact,
            normal: normal,
            critical: .init(
                text: "Build alert",
                systemImage: "exclamationmark.triangle.fill",
                accessibilityLabel: "Build alert"
            )
        )
    )
}
