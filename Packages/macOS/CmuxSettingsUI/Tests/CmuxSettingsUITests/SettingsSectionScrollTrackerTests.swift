import CoreGraphics
import Testing
@testable import CmuxSettingsUI

@Suite("SettingsSectionScrollTracker")
struct SettingsSectionScrollTrackerTests {
    @Test
    func selectsTheLastSectionAtOrAboveTheActivationLine() {
        let tracker = SettingsSectionScrollTracker(activationLine: 20)
        let positions = [
            SettingsSectionScrollPosition(section: .account, minY: -420),
            SettingsSectionScrollPosition(section: .keyboardShortcuts, minY: 19),
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
