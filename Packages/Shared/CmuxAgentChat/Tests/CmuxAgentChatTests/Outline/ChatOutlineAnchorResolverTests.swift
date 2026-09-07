import CmuxAgentChat
import Foundation
import Testing

@Suite("Chat outline anchor resolver")
struct ChatOutlineAnchorResolverTests {
    @Test("finds the matching repeated prompt after ANSI cleanup")
    func findsMatchingRepeatedPromptAfterANSICleanup() {
        let first = ChatOutlineEntry(
            id: "first",
            seq: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Review the login flow",
            hasAlert: false
        )
        let second = ChatOutlineEntry(
            id: "second",
            seq: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            title: "Review the login flow",
            hasAlert: false
        )

        let history = "shell\n\u{1B}[32mReview the login flow\u{1B}[0m\nresult\nReview the login flow\n"
        let row = ChatOutlineAnchorResolver().row(
            for: second,
            among: [first, second],
            in: history
        )

        #expect(row == 3)
    }
}
