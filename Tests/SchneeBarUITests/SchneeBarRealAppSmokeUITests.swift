import Foundation
import XCTest

final class SchneeBarRealAppSmokeUITests: XCTestCase {
    private static let realExternalWidgetSmokeFlag =
        "SCHNEEBAR_REAL_EXTERNAL_WIDGET_SMOKE"
    private static let runnerEnvironmentFlag =
        "SCHNEEBAR_RUNNER_ENVIRONMENT"
    private static let externalWidgetID = "external.ci.smoke"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsShowsExternalWidgetStartupHealth() {
        let app = XCUIApplication()

        launchAndOpenSettings(app)

        let startupStatus = externalWidgetStartupStatus(in: app)
        XCTAssertTrue(
            startupStatus.waitForExistence(timeout: 10),
            "Expected External Widgets startup health in Settings.\n"
                + app.debugDescription
        )

        app.terminate()
    }

    @MainActor
    func testExternalWidgetRegistersFromApplicationSupportOnCI() throws {
        try requireIsolatedCIExternalWidgetSmoke()

        let fileManager = FileManager.default
        let rootURL = try externalWidgetRootURL(fileManager: fileManager)
        let fixtureURL = rootURL.appendingPathComponent(
            "schneebar-ci-smoke.json",
            isDirectory: false
        )
        let app = XCUIApplication()

        app.terminate()
        let createdRoot = try prepareEmptyExternalWidgetRoot(
            rootURL,
            fileManager: fileManager
        )
        try Self.externalWidgetFixtureData.write(to: fixtureURL)

        defer {
            app.terminate()
            try? fileManager.removeItem(at: fixtureURL)
            if createdRoot {
                removeDirectoryIfEmpty(
                    rootURL,
                    fileManager: fileManager
                )
            }
        }

        launchAndOpenSettings(app)

        let startupStatus = externalWidgetStartupStatus(in: app)
        XCTAssertTrue(
            startupStatus.waitForExistence(timeout: 10),
            "Expected External Widgets startup health in Settings.\n"
                + app.debugDescription
        )
        XCTAssertTrue(
            waitForLoadedExternalWidgetStatus(startupStatus),
            "Expected one external widget to finish loading.\n"
                + app.debugDescription
        )

        let widgetToggle = app
            .descendants(matching: .any)
            .matching(
                identifier:
                    "widget-enabled-\(Self.externalWidgetID)"
            )
            .firstMatch
        XCTAssertTrue(
            widgetToggle.waitForExistence(timeout: 10),
            "Expected the production loader to register the CI external widget.\n"
                + app.debugDescription
        )
        XCTAssertEqual(
            toggleState(widgetToggle),
            false,
            "External widgets must remain disabled by default."
        )
    }

    @MainActor
    private func launchAndOpenSettings(_ app: XCUIApplication) {
        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)
    }

    @MainActor
    private func externalWidgetStartupStatus(
        in app: XCUIApplication
    ) -> XCUIElement {
        app
            .descendants(matching: .any)
            .matching(
                identifier: "external-widget-startup-status"
            )
            .firstMatch
    }

    @MainActor
    private func waitForLoadedExternalWidgetStatus(
        _ element: XCUIElement
    ) -> Bool {
        let predicate = NSPredicate(
            format: "label == %@ AND value == %@",
            "External widget startup Loaded",
            "1 external widget loaded."
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: 10
        ) == .completed
    }

    @MainActor
    private func toggleState(
        _ element: XCUIElement
    ) -> Bool? {
        if let value = element.value as? NSNumber {
            return value.boolValue
        }

        guard let value = element.value as? String else {
            return nil
        }

        switch value.lowercased() {
        case "1", "true", "on":
            return true
        case "0", "false", "off":
            return false
        default:
            return nil
        }
    }

    private func requireIsolatedCIExternalWidgetSmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["CI"] == "true",
              environment[Self.realExternalWidgetSmokeFlag] == "1",
              environment[Self.runnerEnvironmentFlag] == "github-hosted"
        else {
            throw XCTSkip(
                "Filesystem-backed external-widget smoke runs only "
                    + "on explicitly opted-in GitHub-hosted Actions CI."
            )
        }
    }

    private func externalWidgetRootURL(
        fileManager: FileManager
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw XCTSkip(
                "User Application Support is unavailable."
            )
        }

        return applicationSupport
            .appendingPathComponent(
                "SchneeBar",
                isDirectory: true
            )
            .appendingPathComponent(
                "ExternalWidgets",
                isDirectory: true
            )
    }

    private func prepareEmptyExternalWidgetRoot(
        _ rootURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw ExternalWidgetRealAppSmokeError.unsafeExistingStorage
            }

            let entries = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil
            )
            guard entries.isEmpty else {
                throw ExternalWidgetRealAppSmokeError.nonEmptyStorage
            }
            return false
        }

        let ownerURL = rootURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: ownerURL.path) {
            let values = try ownerURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw ExternalWidgetRealAppSmokeError.unsafeExistingStorage
            }
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        return true
    }

    private func removeDirectoryIfEmpty(
        _ rootURL: URL,
        fileManager: FileManager
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ),
        entries.isEmpty
        else {
            return
        }

        try? fileManager.removeItem(at: rootURL)
    }

    private static let externalWidgetFixtureData = Data(
        #"""
        {
          "schemaVersion": 1,
          "id": "external.ci.smoke",
          "displayName": "CI External Widget",
          "defaultEnabled": false,
          "defaultOrder": 1200,
          "defaultRepresentation": "normal",
          "visibility": {
            "kind": "always"
          },
          "refresh": {
            "kind": "manual"
          },
          "snapshot": {
            "severity": "nominal",
            "priority": "normal",
            "compact": {
              "text": "CI",
              "systemImage": "checkmark.circle",
              "accessibilityLabel": "CI external widget"
            },
            "normal": {
              "text": "CI smoke",
              "systemImage": "checkmark.circle",
              "accessibilityLabel": "CI external widget smoke"
            }
          }
        }
        """#.utf8
    )
}


private enum ExternalWidgetRealAppSmokeError: Error {
    case nonEmptyStorage
    case unsafeExistingStorage
}
