import CoreGraphics

/// Derives section selection and trailing scroll space from viewport geometry.
struct SettingsSectionScrollTracker: Sendable {
    static let coordinateSpace = "settings-detail-scroll"
    let activationLine: CGFloat

    init(activationLine: CGFloat = 20) {
        self.activationLine = activationLine
    }

    /// Reserves enough space to honor the top-aligned anchor used by click navigation.
    func bottomPadding(viewportHeight: CGFloat, lastSectionHeight: CGFloat) -> CGFloat {
        max(20, viewportHeight - max(0, lastSectionHeight)).rounded(.up)
    }

    /// Selects the nearest eligible header at or above the viewport's activation line.
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
