import CoreGraphics

/// Combines header and content bounds measured in the same viewport coordinate space.
struct SettingsSectionScrollGeometry: Equatable, Sendable {
    var positions: [SettingsSectionScrollPosition] = []
    var contentBottomY: CGFloat?

    /// Excludes trailing padding and remains invariant as the viewport scrolls.
    var lastSectionHeight: CGFloat? {
        guard let contentBottomY, let lastHeaderY = positions.map(\.minY).max() else { return nil }
        return max(0, contentBottomY - lastHeaderY)
    }
}
