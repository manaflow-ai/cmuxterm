import CoreGraphics
import SwiftUI

struct SettingsSectionScrollGeometry: Equatable, Sendable {
    var positions: [SettingsSectionScrollPosition] = []
    var contentBottomY: CGFloat?

    var lastSectionHeight: CGFloat? {
        guard let contentBottomY, let lastHeaderY = positions.map(\.minY).max() else { return nil }
        return max(0, contentBottomY - lastHeaderY)
    }
}

struct SettingsSectionScrollGeometryKey: PreferenceKey {
    static let defaultValue = SettingsSectionScrollGeometry()

    static func reduce(value: inout SettingsSectionScrollGeometry, nextValue: () -> SettingsSectionScrollGeometry) {
        let next = nextValue()
        value.positions.append(contentsOf: next.positions)
        if let contentBottomY = next.contentBottomY {
            value.contentBottomY = contentBottomY
        }
    }
}
