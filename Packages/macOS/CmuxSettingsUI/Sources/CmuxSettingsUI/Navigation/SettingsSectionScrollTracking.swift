import CoreGraphics
import SwiftUI

struct SettingsSectionScrollPosition: Equatable, Sendable {
    let section: SettingsSectionID
    let minY: CGFloat
}

struct SettingsSectionScrollTracker: Sendable {
    static let coordinateSpace = "settings-detail-scroll"
    let activationLine: CGFloat

    init(activationLine: CGFloat = 20) {
        self.activationLine = activationLine
    }

    func bottomPadding(viewportHeight: CGFloat, lastSectionHeight: CGFloat) -> CGFloat {
        max(20, viewportHeight - max(0, lastSectionHeight) - activationLine).rounded(.up)
    }

    func activeSection(
        from positions: [SettingsSectionScrollPosition],
        visibleSections: Set<SettingsSectionID>
    ) -> SettingsSectionID? {
        positions
            .filter { visibleSections.contains($0.section) && $0.minY <= activationLine }
            .max { lhs, rhs in
                if lhs.minY == rhs.minY {
                    return Self.sectionOrder(lhs.section) < Self.sectionOrder(rhs.section)
                }
                return lhs.minY < rhs.minY
            }?
            .section
    }

    private static func sectionOrder(_ section: SettingsSectionID) -> Int {
        SettingsSectionID.allCases.firstIndex(of: section) ?? Int.min
    }
}

extension View {
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

private struct SettingsSectionScrollTrackingModifier: ViewModifier {
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
