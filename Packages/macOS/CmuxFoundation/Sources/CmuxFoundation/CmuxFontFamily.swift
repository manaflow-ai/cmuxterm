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
private final class CmuxFontResolverCache: @unchecked Sendable {
    let familyAvailability = NSCache<NSString, NSNumber>()
    let familyFonts = NSCache<NSString, NSFont>()
}

public enum CmuxFontResolver {
    private static let cache = CmuxFontResolverCache()

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
                  weight: weight,
                  traits: monospacedDigits ? .fixedPitchFontMask : []
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
        weight: NSFont.Weight,
        traits: NSFontTraitMask = []
    ) -> NSFont? {
        guard let family else { return nil }
        let familyKey = family.name.lowercased() as NSString
        if let available = cache.familyAvailability.object(forKey: familyKey) {
            guard available.boolValue else { return nil }
        } else {
            let available = NSFontManager.shared.availableFontFamilies.contains {
                $0.caseInsensitiveCompare(family.name) == .orderedSame
            }
            cache.familyAvailability.setObject(NSNumber(value: available), forKey: familyKey)
            guard available else { return nil }
        }

        let fontKey = "\(familyKey)|\(size)|\(weight.rawValue)|\(traits.rawValue)" as NSString
        if let cached = cache.familyFonts.object(forKey: fontKey) {
            return cached
        }
        let source = NSFont.systemFont(ofSize: size, weight: weight)
        let familyResolved = NSFontManager.shared.convert(source, toFamily: family.name)
        let resolved = traits.isEmpty
            ? familyResolved
            : NSFontManager.shared.convert(familyResolved, toHaveTrait: traits)
        guard resolved.familyName?.caseInsensitiveCompare(family.name) == .orderedSame else {
            return nil
        }
        cache.familyFonts.setObject(resolved, forKey: fontKey)
        return resolved
    }
}
