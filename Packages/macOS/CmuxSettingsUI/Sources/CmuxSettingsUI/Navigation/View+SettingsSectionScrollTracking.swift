import SwiftUI

extension View {
    /// Registers an inline navigation anchor with the same geometry as top-level sections.
    func settingsSectionScrollAnchor(_ section: SettingsSectionID, id: String) -> some View {
        self.id(id).settingsSectionScrollPosition(section, coordinateSpace: SettingsSectionScrollTracker.coordinateSpace)
    }

    func settingsSectionScrollPosition(_ section: SettingsSectionID, coordinateSpace: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsSectionScrollGeometryKey.self,
                    value: SettingsSectionScrollGeometry(positions: [
                        SettingsSectionScrollPosition(
                            section: section,
                            minY: proxy.frame(in: .named(coordinateSpace)).minY
                        )
                    ])
                )
            }
        )
    }

    func settingsSectionScrollTracking(
        selectedSectionRaw: Binding<String>,
        selectedSidebarEntryID: Binding<String>,
        isSearching: Bool,
        visibleSections: Set<SettingsSectionID>
    ) -> some View {
        modifier(
            SettingsSectionScrollTrackingModifier(
                selectedSectionRaw: selectedSectionRaw,
                selectedSidebarEntryID: selectedSidebarEntryID,
                isSearching: isSearching,
                visibleSections: visibleSections
            )
        )
    }
}
