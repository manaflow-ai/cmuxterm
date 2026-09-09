import Foundation
import Testing
@testable import CmuxReadAloud

struct ReadAloudSSEParserTests {
    @Test func fragmentedCRLFMultilineAndBOM() throws {
        let wire = "\u{FEFF}: keepalive\r\nevent: message\r\ndata: {\r\ndata: \"text\":\"日本語😀\"}\r\n\r\n: next\r\rdata: second\n\n"
        var parser = ReadAloudSSEParser()
        var events: [Data] = []
        // Every byte is a separate feed, including UTF-8 code points and CRLF pairs.
        for byte in wire.utf8 {
            if let event = try parser.consume(byte) { events.append(event) }
        }
        try parser.finish()
        #expect(events == [Data("{\n\"text\":\"日本語😀\"}".utf8), Data("second".utf8)])
    }

    @Test func eventIsNotDeliveredBeforeBlankLine() throws {
        var parser = ReadAloudSSEParser()
        for byte in "data: {}\n".utf8 {
            #expect(try parser.consume(byte) == nil)
        }
        #expect(throws: ReadAloudTransportError.truncatedStream) { try parser.finish() }
        #expect(try parser.consume(0x0A) == Data("{}".utf8))
        try parser.finish()
    }

    @Test func multilineAndIgnoredFieldsShareFrameLimit() throws {
        var parser = ReadAloudSSEParser(maximumFrameBytes: 24)
        for byte in "data: 1234\ndata: 5678\n".utf8 { _ = try parser.consume(byte) }
        #expect(throws: ReadAloudTransportError.responseTooLarge) {
            for byte in ": comment without a boundary".utf8 { _ = try parser.consume(byte) }
        }
    }

    @Test func invalidUTF8IsNotSilentlyReplaced() throws {
        var parser = ReadAloudSSEParser()
        for byte in Array("data: ".utf8) + [0xC3, 0x28] { _ = try parser.consume(byte) }
        #expect(throws: ReadAloudTransportError.invalidResponse) { _ = try parser.consume(0x0A) }
    }
}
