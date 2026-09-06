import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The env delivery protocol's pure half: what is typed into `cmux env receive`, how it
/// is chunked, and how the receiver's verdict is read back. The shim's side of the same
/// contract is covered by web/tests/vm-guest-cli.test.ts.
@Suite struct CloudEnvDeliveryTests {
    typealias Entry = CloudEnvDelivery.Entry

    @Test func payloadIsLiteralKeyValueLines() throws {
        let payload = try CloudEnvDelivery.payload([
            Entry(key: "A", value: "1"),
            Entry(key: "SPACEY", value: "  padded  "),
            Entry(key: "QUOTED", value: "'x' \"y\""),
            Entry(key: "EMPTY", value: ""),
        ])
        #expect(String(decoding: payload, as: UTF8.self) == "A=1\nSPACEY=  padded  \nQUOTED='x' \"y\"\nEMPTY=\n")
    }

    @Test func payloadRejectsBadKeysMultilineValuesAndNothing() {
        #expect(throws: CloudEnvDelivery.DeliveryError.invalidKey("1BAD")) {
            try CloudEnvDelivery.payload([Entry(key: "1BAD", value: "v")])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.invalidKey("A-B")) {
            try CloudEnvDelivery.payload([Entry(key: "A-B", value: "v")])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.multilineValue("A")) {
            try CloudEnvDelivery.payload([Entry(key: "A", value: "one\ntwo")])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.emptyPayload) {
            try CloudEnvDelivery.payload([])
        }
    }

    @Test func payloadSizeIsCapped() {
        let huge = String(repeating: "x", count: CloudEnvDelivery.maxPayloadBytes)
        #expect(throws: CloudEnvDelivery.DeliveryError.self) {
            try CloudEnvDelivery.payload([Entry(key: "BIG", value: huge)])
        }
    }

    @Test func wireIsWrappedBase64FollowedByTheEndMarker() throws {
        let payload = try CloudEnvDelivery.payload([Entry(key: "TOKEN", value: String(repeating: "s", count: 200))])
        let wire = String(decoding: CloudEnvDelivery.wire(payload), as: UTF8.self)
        let lines = wire.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Trailing newline, then the marker as the last real line.
        #expect(lines.last == "")
        #expect(lines.dropLast().last == CloudEnvDelivery.endMarker)
        let base64Lines = lines.dropLast(2)
        #expect(!base64Lines.isEmpty)
        #expect(base64Lines.allSatisfy { $0.count <= CloudEnvDelivery.base64LineWidth })
        #expect(base64Lines.dropLast().allSatisfy { $0.count == CloudEnvDelivery.base64LineWidth })
        // Every value never appears in the clear on the wire, and the wire decodes back.
        #expect(!wire.contains("TOKEN="))
        let decoded = Data(base64Encoded: base64Lines.joined())
        #expect(decoded == payload)
    }

    @Test func chunksCoverTheWireExactlyAtAnyCut() throws {
        let wire = CloudEnvDelivery.wire(try CloudEnvDelivery.payload([Entry(key: "K", value: String(repeating: "v", count: 3_000))]))
        let chunks = CloudEnvDelivery.chunks(wire, size: 700)
        #expect(chunks.count == Int((Double(wire.count) / 700).rounded(.up)))
        #expect(chunks.dropLast().allSatisfy { $0.count == 700 })
        #expect(chunks.reduce(Data(), +) == wire)
        #expect(CloudEnvDelivery.chunks(Data(), size: 10).isEmpty)
        #expect(CloudEnvDelivery.chunks(wire, size: 0) == [wire])
    }

    @Test func outcomeReadsTheReceiversVerdictLastLineWins() {
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-READY\nCMUX-ENV-OK keys=3 path=/root/.config/cmux/env\n") == .ok(keys: 3, path: "/root/.config/cmux/env"))
        #expect(CloudEnvDelivery.outcome(fromScreen: "junk\r\nCMUX-ENV-ERR invalid-key 1BAD\n") == .failed("invalid-key 1BAD"))
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-ERR timeout\nCMUX-ENV-OK keys=1\n") == .ok(keys: 1, path: nil))
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-ERR") == .failed("unknown error"))
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-READY\n$ ") == nil)
    }

    @Test func outdatedShimIsRecognizedFromTheScreen() {
        #expect(CloudEnvDelivery.looksLikeOutdatedShim("error: unknown resource scope \"env\"\n"))
        #expect(CloudEnvDelivery.looksLikeOutdatedShim("cmux: unknown env command 'receive'"))
        #expect(!CloudEnvDelivery.looksLikeOutdatedShim("CMUX-ENV-READY"))
    }

    @Test func receiverIsStartedByAbsolutePathWithNoValueInArgv() {
        #expect(CloudEnvDelivery.receiverCommand == ["/usr/local/bin/cmux", "env", "receive"])
        #expect(CloudEnvDelivery.readyTimeoutMs < CloudEnvDelivery.resultTimeoutMs)
        #expect(CloudEnvDelivery.chunkBytes < 4_096, "a canonical-mode PTY line holds at most 4095 bytes")
    }
}
