import XCTest

final class SchneeBarRealAppSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsShowsExternalWidgetStartupHealth() {
        let app = XCUIApplication()

        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let startupStatus = app
            .descendants(matching: .any)
            .matching(
                identifier: "external-widget-startup-status"
            )
            .firstMatch

        XCTAssertTrue(
            startupStatus.waitForExistence(timeout: 10),
            "Expected External Widgets startup health in Settings.\n"
                + app.debugDescription
        )
    }
}
