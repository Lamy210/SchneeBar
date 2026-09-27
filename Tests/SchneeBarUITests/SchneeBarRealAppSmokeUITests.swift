import Foundation
import XCTest

final class SchneeBarRealAppSmokeUITests: XCTestCase {
    private static let externalWidgetID = "external.ci.smoke"
    private static let fixtureFilename = "schneebar-ci-smoke.json"
    private static let sentinelFilename = ".schneebar-ci-smoke-ready"

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
    func testExternalWidgetRegistersFromApplicationSupportOnCI() async throws {
        let fileManager = FileManager.default
        let rootURL = try externalWidgetRootURL(fileManager: fileManager)
        try requirePreparedCIExternalWidgetSmoke(
            rootURL: rootURL,
            fileManager: fileManager
        )

        let app = XCUIApplication()
        app.terminate()
        launchAndOpenSettings(app)
        defer {
            app.terminate()
        }

        let startupStatus = externalWidgetStartupStatus(in: app)
        XCTAssertTrue(
            startupStatus.waitForExistence(timeout: 10),
            "Expected External Widgets startup health in Settings.\n"
                + app.debugDescription
        )
        let loadedExternalWidget = waitForLoadedExternalWidgetStatus(
            startupStatus
        )
        XCTAssertTrue(
            loadedExternalWidget,
            "Expected one external widget to finish loading. "
                + "Observed label=\(startupStatus.label), "
                + "value=\(String(describing: startupStatus.value)).\n"
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

        widgetToggle.click()
        XCTAssertTrue(
            await waitForToggleState(
                widgetToggle,
                expected: true
            ),
            "Expected the external widget to become enabled through Settings."
        )
        try await Task.sleep(for: .milliseconds(500))

        app.terminate()
        launchAndOpenSettings(app)

        let relaunchedStartupStatus = externalWidgetStartupStatus(in: app)
        XCTAssertTrue(
            relaunchedStartupStatus.waitForExistence(timeout: 10),
            "Expected External Widgets startup health after relaunch.\n"
                + app.debugDescription
        )
        XCTAssertTrue(
            waitForLoadedExternalWidgetStatus(
                relaunchedStartupStatus
            ),
            "Expected the external widget to load again after relaunch.\n"
                + app.debugDescription
        )

        let relaunchedToggle = app
            .descendants(matching: .any)
            .matching(
                identifier:
                    "widget-enabled-\(Self.externalWidgetID)"
            )
            .firstMatch
        XCTAssertTrue(
            relaunchedToggle.waitForExistence(timeout: 10),
            "Expected the external widget preference row after relaunch.\n"
                + app.debugDescription
        )
        XCTAssertEqual(
            toggleState(relaunchedToggle),
            true,
            "Expected the explicit external-widget enable preference to persist."
        )

        relaunchedToggle.click()
        XCTAssertTrue(
            await waitForToggleState(
                relaunchedToggle,
                expected: false
            ),
            "Expected the test to restore the external widget to disabled."
        )
        try await Task.sleep(for: .milliseconds(500))
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
            format: "label == %@",
            "External widget startup Loaded. 1 external widget loaded."
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
    private func waitForToggleState(
        _ element: XCUIElement,
        expected: Bool
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if toggleState(element) == expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return toggleState(element) == expected
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

    private func requirePreparedCIExternalWidgetSmoke(
        rootURL: URL,
        fileManager: FileManager
    ) throws {
        let fixtureURL = rootURL.appendingPathComponent(
            Self.fixtureFilename,
            isDirectory: false
        )
        let sentinelURL = rootURL.appendingPathComponent(
            Self.sentinelFilename,
            isDirectory: false
        )

        guard fileManager.fileExists(atPath: fixtureURL.path),
              fileManager.fileExists(atPath: sentinelURL.path)
        else {
            throw XCTSkip(
                "Filesystem-backed external-widget smoke requires "
                    + "the GitHub-hosted CI fixture."
            )
        }

        let rootValues = try rootURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        let fixtureValues = try fixtureURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        let sentinelValues = try sentinelURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )

        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              fixtureValues.isRegularFile == true,
              fixtureValues.isSymbolicLink != true,
              sentinelValues.isRegularFile == true,
              sentinelValues.isSymbolicLink != true
        else {
            throw ExternalWidgetRealAppSmokeError.unsafePreparedStorage
        }
    }
}

private enum ExternalWidgetRealAppSmokeError: Error {
    case unsafePreparedStorage
}
