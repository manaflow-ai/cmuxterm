import XCTest

final class SettingsComputersBehaviorUITests: SettingsUITestCase {
    func testComputersSectionOffersMacPairing() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        let before = XCTAttachment(screenshot: window.screenshot())
        before.name = "Settings before opening Computers"
        before.lifetime = .keepAlways
        add(before)

        navigate(window, to: "Computers")

        XCTAssertTrue(window.textFields["SettingsComputersPairingInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["SettingsComputersPair"].exists)
        XCTAssertTrue(window.buttons["SettingsComputersShowPairing"].exists)

        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Computers pairing controls"
        after.lifetime = .keepAlways
        add(after)
    }
}
