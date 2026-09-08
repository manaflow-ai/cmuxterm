import Foundation
import Testing
import CmuxTerminalCore

@Suite("Terminal prompt write cursor")
struct TerminalPromptWriteSnapshotTests {
    @Test func capturesWriteRowNotBottomOfReviewViewport() {
        let data = Data(#"{"anchor":"screen","active_screen":"primary","history_rows":100,"rows":30,"cursor":{"row":4}}"#.utf8)
        #expect(TerminalPromptWriteSnapshot.decodeAnchor(from: data, rowSpaceRevision: 7) == TerminalPromptAnchor(row: 104, rowSpaceRevision: 7))
    }

    @Test(arguments: [
        #"{"anchor":"viewport","active_screen":"primary","history_rows":100,"rows":30,"cursor":{"row":4}}"#,
        #"{"anchor":"screen","active_screen":"alternate","history_rows":0,"rows":30,"cursor":{"row":4}}"#,
        #"{"anchor":"screen","active_screen":"primary","history_rows":100,"rows":30,"cursor":{"row":30}}"#,
        #"{"anchor":"screen","active_screen":"primary","history_rows":18446744073709551615,"rows":30,"cursor":{"row":1}}"#,
        #"{"anchor":"screen","active_screen":"primary","history_rows":9223372036854775807,"rows":30,"cursor":{"row":1}}"#,
        #"{"anchor":"screen","active_screen":"primary","history_rows":100,"rows":30,"cursor":{"row":-1}}"#,
        #"{"anchor":"screen","active_screen":"primary","history_rows":100,"rows":0,"cursor":{"row":0}}"#,
        #"{"anchor":"screen","active_screen":"primary","history_rows":100,"rows":30}"#,
        "invalid JSON",
    ])
    func rejectsUntrustworthyPosition(json: String) {
        #expect(TerminalPromptWriteSnapshot.decodeAnchor(from: Data(json.utf8), rowSpaceRevision: 7) == nil)
    }
}
