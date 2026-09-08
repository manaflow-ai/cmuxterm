import Testing
import CmuxTerminalCore

@Suite("Terminal prompt history")
struct TerminalPromptHistoryTests {
    @Test(arguments: [(0, nil), (10, "first"), (15, "first"), (39, "first"), (40, "second"), (79, "second"), (80, "third"), (100, "third")] as [(Int, String?)])
    func selectsOwningTurn(row: Int, expected: String?) {
        let history = threeTurns()
        #expect(history.selectedEntry(viewportTopRow: row, isAtBottom: false, rowSpaceRevision: 1)?.preview == expected)
    }

    @Test func bottomUsesLatestSubmissionRatherThanViewportTop() {
        let history = threeTurns()
        #expect(history.selectedEntry(viewportTopRow: 15, isAtBottom: true, rowSpaceRevision: 1)?.preview == "third")
    }

    @Test func unknownRevisionNeverAttributesHistoricalOutput() {
        var history = threeTurns()
        #expect(history.selectedEntry(viewportTopRow: 50, isAtBottom: false, rowSpaceRevision: 2) == nil)
        history.reconcile(rowSpaceRevision: 2)
        #expect(history.entries.isEmpty)
        #expect(history.selectedEntry(viewportTopRow: 50, isAtBottom: true, rowSpaceRevision: 2)?.preview == "third")
    }

    @Test func sameRowReplacesBoundaryAndBackwardRedrawDropsFutureRows() {
        var history = threeTurns()
        history.record(preview: "replacement", anchor: anchor(40))
        #expect(history.entries.map(\.preview) == ["first", "replacement"])
        #expect(history.selectedEntry(viewportTopRow: 100, isAtBottom: false, rowSpaceRevision: 1)?.preview == "replacement")
    }

    @Test func unanchoredSubmissionInvalidatesHistoricalAttribution() {
        var history = threeTurns()
        history.record(preview: "unanchored", anchor: nil)
        #expect(history.entries.isEmpty)
        #expect(history.selectedEntry(viewportTopRow: 50, isAtBottom: false, rowSpaceRevision: 1) == nil)
        #expect(history.selectedEntry(viewportTopRow: 50, isAtBottom: true, rowSpaceRevision: 1)?.preview == "unanchored")
    }

    @Test func newRevisionStartsNewHistory() {
        var history = threeTurns()
        history.record(preview: "new screen", anchor: TerminalPromptAnchor(row: 1, rowSpaceRevision: 2))
        #expect(history.entries.map(\.preview) == ["new screen"])
    }

    @Test func whitespaceIsCollapsedAndBlankSubmissionsAreIgnored() {
        var history = TerminalPromptHistory()
        history.record(preview: "  日本語\n\twith   spaces  ", anchor: anchor(10))
        history.record(preview: " \n\t", anchor: anchor(20))
        #expect(history.entries.count == 1)
        #expect(history.latest?.preview == "日本語 with spaces")
    }

    @Test func separateHistoriesNeverShareTurns() {
        let first = threeTurns()
        var second = TerminalPromptHistory()
        second.record(preview: "other pane", anchor: anchor(10))
        #expect(first.latest?.preview == "third")
        #expect(second.latest?.preview == "other pane")
    }

    @Test func anchorRejectsNegativeRowsAndAcceptsZero() {
        let negative: TerminalPromptAnchor? = TerminalPromptAnchor(row: -1, rowSpaceRevision: 1)
        let zero: TerminalPromptAnchor? = TerminalPromptAnchor(row: 0, rowSpaceRevision: 1)
        #expect(negative == nil)
        #expect(zero?.row == 0)
    }

    private func anchor(_ row: Int) -> TerminalPromptAnchor? {
        TerminalPromptAnchor(row: row, rowSpaceRevision: 1)
    }

    private func threeTurns() -> TerminalPromptHistory {
        var history = TerminalPromptHistory()
        history.record(preview: "first", anchor: anchor(10))
        history.record(preview: "second", anchor: anchor(40))
        history.record(preview: "third", anchor: anchor(80))
        return history
    }
}
