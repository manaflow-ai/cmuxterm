import AppKit
import Testing
@testable import CmuxFoundation

@Suite("cmux font family resolution")
struct CmuxFontFamilyTests {
    @Test("Empty values resolve to the system fallback")
    func emptyValuesUseSystemFont() {
        #expect(CmuxFontFamily(rawValue: " \n\t") == nil)
        let font = CmuxFontResolver.appKitFont(
            family: " \n\t",
            size: 13,
            weight: .regular,
            monospaced: false
        )
        #expect(font.pointSize == 13)
    }

    @Test("Installed family names are retained by AppKit resolution")
    func installedFamilyResolves() throws {
        let family = try #require(NSFontManager.shared.availableFontFamilies.first)
        let font = CmuxFontResolver.appKitFont(
            family: family,
            size: 13,
            weight: .regular,
            monospaced: false
        )
        #expect(font.familyName?.caseInsensitiveCompare(family) == .orderedSame)
    }

    @Test("Unknown family names fall back without blanking the text")
    func unknownFamilyFallsBack() {
        let font = CmuxFontResolver.appKitFont(
            family: "cmux-font-family-that-is-not-installed",
            size: 13,
            weight: .regular,
            monospaced: false
        )
        #expect(font.pointSize == 13)
        #expect(font.familyName?.caseInsensitiveCompare("cmux-font-family-that-is-not-installed") != .orderedSame)
    }
}
