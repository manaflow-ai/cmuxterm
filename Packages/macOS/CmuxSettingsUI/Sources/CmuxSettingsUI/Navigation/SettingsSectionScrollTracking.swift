import CoreGraphics
import SwiftUI

struct SettingsSectionScrollPosition: Equatable, Sendable {
    let section: SettingsSectionID
    let minY: CGFloat
}

enum SettingsSectionScrollTracking {
    static let coordinateSpace = "settings-detail-scroll"
}

struct SettingsSectionScrollTracker: Sendable {
    let activationLine: CGFloat

    init(activationLine: CGFloat) {
        self.activationLine = activationLine
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

private struct SettingsSectionScrollPositionKey: PreferenceKey {
    static let defaultValue: [SettingsSectionScrollPosition] = []

    static func reduce(
        value: inout [SettingsSectionScrollPosition],
        nextValue: () -> [SettingsSectionScrollPosition]
    ) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func settingsSectionScrollPosition(_ section: SettingsSectionID, coordinateSpace: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsSectionScrollPositionKey.self,
                    value: [
                        SettingsSectionScrollPosition(
                            section: section,
                            minY: proxy.frame(in: .named(coordinateSpace)).minY
                        )
                    ]
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
        content.onPreferenceChange(SettingsSectionScrollPositionKey.self) { positions in
            let tracker = SettingsSectionScrollTracker(activationLine: 20)
            guard let section = tracker.activeSection(from: positions, visibleSections: visibleSections) else { return }
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
