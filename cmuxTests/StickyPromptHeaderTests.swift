import Testing

@Suite("Sticky prompt header")
struct StickyPromptHeaderTests {
    @Test("selects the prompt whose output contains the viewport")
    func selectsPromptForViewport() {
        let prompts = [
            StickyPromptHeaderEntry(id: "first", row: 10, preview: "first prompt"),
            StickyPromptHeaderEntry(id: "second", row: 40, preview: "second prompt"),
            StickyPromptHeaderEntry(id: "third", row: 80, preview: "third prompt"),
        ]

        #expect(StickyPromptHeaderSelection.entry(for: 15, in: prompts)?.id == "first")
        #expect(StickyPromptHeaderSelection.entry(for: 45, in: prompts)?.id == "second")
        #expect(StickyPromptHeaderSelection.entry(for: 100, in: prompts)?.id == "third")
        #expect(StickyPromptHeaderSelection.entry(for: 0, in: prompts)?.id == "first")
    }
}
