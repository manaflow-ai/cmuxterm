import SwiftUI

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
