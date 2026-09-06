import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalBlueprintLayout")
struct TerminalBlueprintLayoutTests {
    @Test("fractions clamp into the allowed split range")
    func clampsFractions() {
        #expect(TerminalBlueprintLayout.clampedFraction(0.02) == TerminalBlueprintLayout.minimumSplitFraction)
        #expect(TerminalBlueprintLayout.clampedFraction(0.99) == TerminalBlueprintLayout.maximumSplitFraction)
        #expect(TerminalBlueprintLayout.clampedFraction(0.5) == 0.5)
        #expect(TerminalBlueprintLayout.clampedFraction(.nan) == TerminalBlueprintLayout.defaultSplitFraction)
    }

    @Test("collapsed drawers are exactly one header tall")
    func collapsedHeight() {
        #expect(TerminalBlueprintLayout.collapsed.drawerHeight(containerHeight: 800) == TerminalBlueprintLayout.headerHeight)
        #expect(TerminalBlueprintLayout.collapsed.fraction == nil)
    }

    @Test("split drawers take their fraction of the pane")
    func splitHeight() {
        let layout = TerminalBlueprintLayout.split(fraction: 0.4)
        #expect(layout.drawerHeight(containerHeight: 1000) == 400)
    }

    @Test("the terminal keeps its minimum height however large the drawer is")
    func keepsMinimumTerminalHeight() {
        let enlarged = TerminalBlueprintLayout.enlarged
        let container = 300.0
        let height = enlarged.drawerHeight(containerHeight: container)
        #expect(container - height >= TerminalBlueprintLayout.minimumTerminalHeight)
        #expect(height >= TerminalBlueprintLayout.headerHeight)
    }

    @Test("degenerate pane heights fall back to the header")
    func degenerateContainer() {
        #expect(TerminalBlueprintLayout.split(fraction: 0.5).drawerHeight(containerHeight: 0) == TerminalBlueprintLayout.headerHeight)
        #expect(TerminalBlueprintLayout.enlarged.drawerHeight(containerHeight: .nan) == TerminalBlueprintLayout.headerHeight)
    }

    @Test("layouts round-trip through JSON", arguments: [
        TerminalBlueprintLayout.collapsed,
        .split(fraction: 0.33),
        .enlarged,
    ])
    func codableRoundTrip(layout: TerminalBlueprintLayout) throws {
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TerminalBlueprintLayout.self, from: data)
        #expect(decoded == layout)
    }

    @Test("a split without a stored fraction decodes to the default and out-of-range fractions clamp")
    func lenientDecoding() throws {
        let missing = try JSONDecoder().decode(
            TerminalBlueprintLayout.self,
            from: Data(#"{"kind":"split"}"#.utf8)
        )
        #expect(missing == .split(fraction: TerminalBlueprintLayout.defaultSplitFraction))
        let huge = try JSONDecoder().decode(
            TerminalBlueprintLayout.self,
            from: Data(#"{"kind":"split","fraction":4}"#.utf8)
        )
        #expect(huge == .split(fraction: TerminalBlueprintLayout.maximumSplitFraction))
    }
}
