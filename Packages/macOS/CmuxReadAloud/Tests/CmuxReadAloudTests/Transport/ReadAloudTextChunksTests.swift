import Foundation
import Testing
@testable import CmuxReadAloud

struct ReadAloudTextChunksTests {
    @Test func prefersParagraphThenSentenceWithoutDroppingWhitespace() throws {
        var paragraphs = ReadAloudTextChunks(text: "One.\nTwo. tail", maximumUTF16Count: 10)
        #expect(try paragraphs.next() == "One.\n")
        #expect(try paragraphs.next() == "Two. tail")
        #expect(try paragraphs.next() == nil)
        var sentences = ReadAloudTextChunks(text: "One. Two. Three.", maximumUTF16Count: 10)
        #expect(try sentences.next() == "One. Two.")
        #expect(try sentences.next() == " Three.")
        #expect(try sentences.next() == nil)
    }

    @Test func unbrokenUnicodePreservesGraphemesAndEveryScalar() throws {
        let text = String(repeating: "👨‍👩‍👧‍👦e\u{301}日本語😀", count: 9)
        let pieces = try partition(text, maximumUTF16Count: 16)
        #expect(pieces.joined().unicodeScalars.elementsEqual(text.unicodeScalars))
        #expect(pieces.allSatisfy { $0.utf16.count <= 16 })
        #expect(pieces.flatMap(Array.init) == Array(text))
    }

    @Test func giantCombiningGraphemeFallsBackLosslessly() throws {
        let text = "a" + String(repeating: "\u{301}", count: 30) + "😀end"
        let pieces = try partition(text, maximumUTF16Count: 8)
        #expect(pieces.joined().unicodeScalars.elementsEqual(text.unicodeScalars))
        #expect(pieces.allSatisfy { !$0.isEmpty && $0.utf16.count <= 8 })
    }

    @Test func providerBoundaryIsStrictlyBelowTenThousand() throws {
        let text = String(repeating: "😀", count: 5_000)
        var chunks = ReadAloudTextChunks(text: text)
        let first = try #require(try chunks.next())
        let second = try #require(try chunks.next())
        #expect(first.utf16.count == 9_998)
        #expect(second == "😀")
        #expect(first + second == text)
        #expect(try chunks.next() == nil)
    }

    @Test func whitespacePartitionIsNotSilentlyTrimmed() throws {
        let text = " \t\n\r\n   "
        #expect(try partition(text, maximumUTF16Count: 4).joined() == text)
        var empty = ReadAloudTextChunks(text: "")
        #expect(try empty.next() == nil)
    }

    private func partition(_ text: String, maximumUTF16Count: Int) throws -> [String] {
        var chunks = ReadAloudTextChunks(text: text, maximumUTF16Count: maximumUTF16Count)
        var result: [String] = []
        while let chunk = try chunks.next() { result.append(chunk) }
        return result
    }
}
