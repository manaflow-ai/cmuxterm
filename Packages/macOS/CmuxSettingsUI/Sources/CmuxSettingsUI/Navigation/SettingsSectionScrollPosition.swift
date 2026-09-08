import CoreGraphics

/// A section header's vertical position in the settings detail viewport.
struct SettingsSectionScrollPosition: Equatable, Sendable {
    let section: SettingsSectionID
    let minY: CGFloat
}
