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

        let escapePrefixEntry = ChatOutlineEntry(
            id: "escape-prefix",
            seq: 3,
            timestamp: Date(timeIntervalSince1970: 3),
            title: "mReview the login flow",
            hasAlert: false
        )
        #expect(ChatOutlineAnchorResolver().row(
            for: escapePrefixEntry,
            among: [escapePrefixEntry],
            in: "\u{1B}[31mReview the login flow\u{1B}[0m\n"
        ) == nil)
    }

    @Test("matches wrapped prompts without counting incidental mentions")
    func matchesWrappedPromptWithoutCountingIncidentalMentions() {
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

        let history = "shell\nI will review the login flow\n❯ Review the\nlogin flow\n"
        let resolver = ChatOutlineAnchorResolver()
        let firstRow = resolver.row(
            for: first,
            among: [first, second],
            in: history
        )
        let secondRow = resolver.row(
            for: second,
            among: [first, second],
            in: history
        )

        #expect(firstRow == 2)
        #expect(secondRow == nil)
    }

    @Test("anchors start at prompt rows and support clipped titles")
    func anchorsStartAtPromptRowsAndSupportClippedTitles() {
        let title = String(repeating: "a", count: 160)
        let entry = ChatOutlineEntry(
            id: "prompt",
            seq: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            title: title,
            hasAlert: false
        )
        let fullPrompt = String(repeating: "a", count: 180)

        #expect(ChatOutlineAnchorResolver().row(
            for: entry,
            among: [entry],
            in: "\n❯ \(fullPrompt)\n"
        ) == 1)

        let firstRepeated = ChatOutlineEntry(
            id: "first-repeated",
            seq: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            title: "Review the login flow",
            hasAlert: false
        )
        let secondRepeated = ChatOutlineEntry(
            id: "second-repeated",
            seq: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            title: "Review the login flow",
            hasAlert: false
        )
        let repeatedHistory = "\n❯ Review the login flow\nI will Review the login flow\n❯ Review the login flow\n"
        #expect(ChatOutlineAnchorResolver().row(
            for: secondRepeated,
            among: [firstRepeated, secondRepeated],
            in: repeatedHistory
        ) == 3)
    }
}
