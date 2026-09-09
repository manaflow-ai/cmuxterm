import Foundation
import Testing
@testable import CmuxReadAloud

struct MiniMaxAudioParserTests {
    @Test func emitsIncrementallyWithoutReplayingFinalAggregate() throws {
        var parser = MiniMaxAudioParser()
        #expect(try parser.consume(event(audio: "01000200", status: 1)) == Data([1, 0, 2, 0]))
        #expect(!parser.isComplete)
        #expect(try parser.consume(event(audio: "0300", status: 1)) == Data([3, 0]))
        #expect(try parser.consume(event(audio: "010002000300", status: 2)) == nil)
        try parser.finish()
    }

    @Test func nullDataDoesNotCompleteStreamAndSplitSamplesRemainLossless() throws {
        var parser = MiniMaxAudioParser()
        #expect(try parser.consume(Data(#"{"data":null,"base_resp":{"status_code":0}}"#.utf8)) == nil)
        #expect(try parser.consume(event(audio: "aB", status: 1)) == nil)
        #expect(try parser.consume(event(audio: "cD0102ff", status: 1)) == Data([0xAB, 0xCD, 1, 2]))
        #expect(try parser.consume(event(audio: "80", status: 1)) == Data([0xFF, 0x80]))
        _ = try parser.consume(event(audio: nil, status: 2))
        try parser.finish()
    }

    @Test func providerErrorInsideSuccessHTTPBodyIsSanitized() throws {
        var parser = MiniMaxAudioParser()
        let body = Data(#"{"data":null,"base_resp":{"status_code":1004,"status_msg":"selected text and secret credential"}}"#.utf8)
        #expect(throws: ReadAloudTransportError.authentication) { _ = try parser.consume(body) }
        _ = try parser.consume(event(audio: "0000", status: 1))
        #expect(throws: ReadAloudTransportError.authentication) { _ = try parser.consume(body) }
    }

    @Test(arguments: ["0", "0g", "é0", "00 0"])
    func rejectsMalformedHex(hex: String) throws {
        var parser = MiniMaxAudioParser()
        #expect(throws: ReadAloudTransportError.invalidResponse) {
            _ = try parser.consume(event(audio: hex, status: 1))
        }
    }

    @Test func prematureEOFAndDanglingSampleAreFailures() throws {
        var parser = MiniMaxAudioParser()
        _ = try parser.consume(event(audio: "0000", status: 1))
        #expect(throws: ReadAloudTransportError.truncatedStream) { try parser.finish() }
        _ = try parser.consume(event(audio: "ff", status: 1))
        #expect(throws: ReadAloudTransportError.truncatedStream) {
            _ = try parser.consume(event(audio: nil, status: 2))
        }
    }

    @Test func completionWithoutDeltaAudioIsNotSuccess() throws {
        var parser = MiniMaxAudioParser()
        _ = try parser.consume(event(audio: "0000", status: 2))
        #expect(throws: ReadAloudTransportError.noAudio) { try parser.finish() }
    }

    @Test func missingFinalStatusCannotBeReplacedByDoneSentinel() throws {
        var parser = MiniMaxAudioParser()
        _ = try parser.consume(event(audio: "0000", status: 1))
        #expect(throws: ReadAloudTransportError.truncatedStream) {
            _ = try parser.consume(Data("[DONE]".utf8))
        }
    }

    @Test func mismatchedAudioFormatIsRejectedBeforePlayback() throws {
        var parser = MiniMaxAudioParser()
        let event = Data(#"{"data":{"status":1,"audio":"0000"},"extra_info":{"audio_format":"mp3"},"base_resp":{"status_code":0}}"#.utf8)
        #expect(throws: ReadAloudTransportError.invalidResponse) { _ = try parser.consume(event) }
    }

    private func event(audio: String?, status: Int) -> Data {
        let encodedAudio = audio.map { "\"\($0)\"" } ?? "null"
        return Data("{\"data\":{\"audio\":\(encodedAudio),\"status\":\(status)},\"base_resp\":{\"status_code\":0}}".utf8)
    }
}
