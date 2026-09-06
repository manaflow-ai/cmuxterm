public import AppKit
public import SwiftUI

/// A normalized, optional font-family override shared by AppKit and SwiftUI.
/// An empty value means that the platform's system font should be used.
public struct CmuxFontFamily: Equatable, Hashable, Sendable {
    public let name: String

    public init?(_ rawValue: String?) {
        guard let normalized = Self.normalizedName(rawValue) else { return nil }
        name = normalized
    }

    public init?(rawValue: String) {
        self.init(rawValue)
    }

    public static func normalizedName(_ rawValue: String?) -> String? {
        rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// Resolves one family override consistently for native and SwiftUI sidebar
/// renderers. Invalid names deliberately return the platform fallback.
public enum CmuxFontResolver {
    public static func appKitFont(
        family: String?,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        monospacedDigits: Bool = false
    ) -> NSFont {
        let fallback = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
        guard let family = CmuxFontFamily(family),
              let resolved = familyFont(
                  family,
                  size: size,
                  weight: weight
              ) else {
            return fallback
        }
        return resolved
    }

    public static func swiftUIFont(
        family: String?,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> Font {
        var font: Font
        if let family = CmuxFontFamily(family),
           familyFont(family, size: size, weight: .regular) != nil {
            font = Font.custom(family.name, size: size).weight(weight)
        } else {
            font = Font.system(size: size, weight: weight, design: design)
        }
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private static func familyFont(
        _ family: CmuxFontFamily?,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont? {
        guard let family else { return nil }
        let source = NSFont.systemFont(ofSize: size, weight: weight)
        let resolved = NSFontManager.shared.convert(source, toFamily: family.name)
        guard resolved.familyName?.caseInsensitiveCompare(family.name) == .orderedSame else {
            return nil
        }
        return resolved
    }
}
