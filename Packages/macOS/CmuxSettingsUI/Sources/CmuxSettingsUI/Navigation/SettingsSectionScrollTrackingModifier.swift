import SwiftUI

/// Updates selection from scroll geometry without issuing another navigation request.
struct SettingsSectionScrollTrackingModifier: ViewModifier {
    @Binding var selectedSectionRaw: String
    @Binding var selectedSidebarEntryID: String
    let isSearching: Bool
    let visibleSections: Set<SettingsSectionID>

    func body(content: Content) -> some View {
        content.onPreferenceChange(SettingsSectionScrollGeometryKey.self) { geometry in
            let tracker = SettingsSectionScrollTracker()
            guard let section = tracker.activeSection(from: geometry.positions, visibleSections: visibleSections) else { return }
            if selectedSectionRaw != section.rawValue {
                selectedSectionRaw = section.rawValue
            }
            guard !isSearching else { return }
            let entryID = "section:\(section.rawValue)"
            if selectedSidebarEntryID != entryID {
                selectedSidebarEntryID = entryID
            }
        }
    }
}
