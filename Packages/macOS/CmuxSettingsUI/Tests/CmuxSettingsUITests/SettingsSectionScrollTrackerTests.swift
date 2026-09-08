import CoreGraphics
import Testing
@testable import CmuxSettingsUI

@Suite("SettingsSectionScrollTracker")
struct SettingsSectionScrollTrackerTests {
    @Test(arguments: [(700.0, 80.0, 620.0), (900.0, 80.0, 820.0), (700.0, 800.0, 20.0), (700.25, 80.1, 621.0)])
    func reservesOnlyTheSpaceNeededToTopAlignTheLastHeader(viewport: Double, tail: Double, expected: Double) {
        let tracker = SettingsSectionScrollTracker()
        #expect(tracker.bottomPadding(viewportHeight: viewport, lastSectionHeight: tail) == CGFloat(expected))
    }

    @Test(arguments: [900.0, -90.0])
    func lastSectionHeightDoesNotDependOnScrollOffset(headerY: Double) {
        let geometry = SettingsSectionScrollGeometry(
            positions: [
                SettingsSectionScrollPosition(section: .settingsJSON, minY: headerY - 200),
                SettingsSectionScrollPosition(section: .reset, minY: headerY),
            ],
            contentBottomY: headerY + 80
        )
        #expect(geometry.lastSectionHeight == 80)
    }

    @Test(arguments: [19.0, 20.0])
    func selectsTheLastSectionAtOrAboveTheActivationLine(headerY: Double) {
        let tracker = SettingsSectionScrollTracker(activationLine: 20)
        let positions = [
            SettingsSectionScrollPosition(section: .account, minY: -420),
            SettingsSectionScrollPosition(section: .keyboardShortcuts, minY: headerY),
            SettingsSectionScrollPosition(section: .workspaceColors, minY: 280),
        ]

        #expect(
            tracker.activeSection(from: positions, visibleSections: Set(SettingsSectionID.allCases))
                == .keyboardShortcuts
        )
    }

    @Test
    func ignoresSectionsThatAreNotInTheSidebar() {
        let tracker = SettingsSectionScrollTracker(activationLine: 20)
        let positions = [
            SettingsSectionScrollPosition(section: .account, minY: -420),
            SettingsSectionScrollPosition(section: .cloudMachines, minY: 10),
            SettingsSectionScrollPosition(section: .keyboardShortcuts, minY: 80),
        ]

        #expect(
            tracker.activeSection(
                from: positions,
                visibleSections: [.account, .keyboardShortcuts]
            ) == .account
        )
    }
}
