import XCTest

final class SettingsSectionScrollTrackingUITests: SettingsUITestCase {
    func testSidebarSelectionTracksDetailScroll() {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        let account = window.cells.containing(.staticText, identifier: "Account").firstMatch
        let keyboardShortcuts = window.cells.containing(.staticText, identifier: "Keyboard Shortcuts").firstMatch
        let detail = window.scrollViews["SettingsDetailScrollView"]

        XCTAssertTrue(poll(timeout: 5.0) { account.exists && account.isSelected })
        XCTAssertTrue(detail.waitForExistence(timeout: 5.0))

        for _ in 0..<12 {
            if poll(timeout: 0.5) { keyboardShortcuts.exists && keyboardShortcuts.isSelected } {
                break
            }
            detail.swipeUp()
        }

        XCTAssertTrue(
            poll(timeout: 5.0) { keyboardShortcuts.exists && keyboardShortcuts.isSelected },
            "Keyboard Shortcuts should become the selected ToC section after scrolling the detail"
        )

        for _ in 0..<12 {
            if poll(timeout: 0.5) { account.isSelected } {
                break
            }
            detail.swipeDown()
        }
        XCTAssertTrue(poll(timeout: 5.0) { account.isSelected }, "Scrolling back should select Account")
    }

    func testSidebarSelectionKeepsInlineNavigation() {
        assertSidebarNavigationTracksHeader(titles: ["Import Browser Data", "Browser", "Import Browser Data"])
    }

    func testSidebarSelectionKeepsTrailingNavigation() {
        assertSidebarNavigationTracksHeader(titles: ["Reset", "cmux.json", "Workspace Colors", "Reset"])
    }

    private func assertSidebarNavigationTracksHeader(titles: [String]) {
        let app = makeLaunchedApp()
        let window = openSettings(app)
        defer { closeSettings(app, window) }
        let detail = window.scrollViews["SettingsDetailScrollView"]

        for title in titles {
            navigate(window, to: title)
            let row = window.cells.containing(.staticText, identifier: title).firstMatch
            let header = detail.staticTexts[title].firstMatch
            XCTAssertTrue(
                poll(timeout: 5.0) {
                    guard row.isSelected, header.exists, header.isHittable else { return false }
                    let offset = header.frame.minY - detail.frame.minY
                    return (-2...40).contains(offset)
                },
                "\(title) should stay selected with its header at the top of the detail viewport"
            )
        }
    }
}
