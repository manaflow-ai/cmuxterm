import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalBlueprintPromptComposer")
struct TerminalBlueprintPromptComposerTests {
    private let input = TerminalBlueprintPromptComposer.Input(
        revision: 12,
        elementCount: 3,
        pngPath: "/tmp/blueprint.png",
        mermaid: "flowchart LR\n  A --> B\n",
        summary: "#a rectangle \"A\" (0,0 10x10)",
        sceneJSON: #"{"elements":[]}"#
    )

    @Test func defaultSendsPNGPathAndMermaidWithoutTrailingNewline() {
        let (text, formats) = TerminalBlueprintPromptComposer.compose(input, options: TerminalBlueprintSendOptions())

        #expect(formats == ["png", "mermaid"])
        #expect(text == """
        Blueprint from this terminal (revision 12, 3 elements). PNG: /tmp/blueprint.png
        ```mermaid
        flowchart LR
          A --> B
        ```
        """)
        #expect(!text.hasSuffix("\n"))
    }

    @Test func fallsBackToTheSummaryWhenNoMermaidExists() {
        var noMermaid = input
        noMermaid.mermaid = nil
        noMermaid.pngPath = nil

        let (text, formats) = TerminalBlueprintPromptComposer.compose(noMermaid, options: TerminalBlueprintSendOptions())

        #expect(formats == ["summary"])
        #expect(text == """
        Blueprint from this terminal (revision 12, 3 elements).
        Canvas summary:
        ```text
        #a rectangle "A" (0,0 10x10)
        ```
        """)
    }

    @Test func prefixSummaryAndJSONAreOptIn() {
        let options = TerminalBlueprintSendOptions(
            includeMermaid: false,
            includePNG: false,
            includeSummary: true,
            includeJSON: true,
            promptPrefix: "  Here is my sketch:  "
        )

        let (text, formats) = TerminalBlueprintPromptComposer.compose(input, options: options)

        #expect(formats == ["summary", "json"])
        #expect(text.hasPrefix("Here is my sketch:\nBlueprint from this terminal (revision 12, 3 elements).\n"))
        #expect(text.contains("```json\n{\"elements\":[]}\n```"))
        #expect(!text.contains("```mermaid"))
        #expect(!text.contains("PNG:"))
    }

    @Test func singularElementCount() {
        var one = input
        one.elementCount = 1
        one.pngPath = nil
        let (text, _) = TerminalBlueprintPromptComposer.compose(one, options: TerminalBlueprintSendOptions(includeMermaid: false, includePNG: false))
        #expect(text == "Blueprint from this terminal (revision 12, 1 element).")
    }
}
