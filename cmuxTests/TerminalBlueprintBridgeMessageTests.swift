import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalBlueprintBridgeMessage")
struct TerminalBlueprintBridgeMessageTests {
    @Test("decodes every message the page can post")
    func decodesKnownMessages() throws {
        #expect(TerminalBlueprintBridgeMessage(body: ["type": "ready"]) == .ready)
        #expect(TerminalBlueprintBridgeMessage(body: ["type": "requestTerminalFocus"]) == .requestTerminalFocus)
        #expect(TerminalBlueprintBridgeMessage(body: ["type": "error", "message": "boom"]) == .error(message: "boom"))
        #expect(
            TerminalBlueprintBridgeMessage(body: [
                "type": "sceneChanged",
                "sceneJSON": "{}",
                "elementCount": 4.0,
                "digest": "abc",
            ]) == .sceneChanged(sceneJSON: "{}", elementCount: 4, digest: "abc")
        )
        #expect(
            TerminalBlueprintBridgeMessage(body: ["type": "exportFailed", "requestId": "r1", "message": "nope"])
                == .exportFailed(requestID: "r1", message: "nope")
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let result = try #require(TerminalBlueprintBridgeMessage(body: [
            "type": "exportResult",
            "requestId": "r2",
            "pngBase64": png.base64EncodedString(),
            "mermaid": "flowchart LR",
            "sceneJSON": "{\"elements\":[]}",
            "width": 640,
            "height": 480.5,
        ]))
        guard case .exportResult(let export) = result else {
            Issue.record("expected exportResult, got \(result)")
            return
        }
        #expect(export.requestID == "r2")
        #expect(export.pngData == png)
        #expect(export.svg == nil)
        #expect(export.mermaid == "flowchart LR")
        #expect(export.width == 640)
        #expect(export.height == 480.5)
    }

    @Test("malformed or unknown bodies decode to nil")
    func rejectsMalformed() {
        let bodies: [Any] = [
            "not a dictionary",
            ["type": "unknown"],
            ["type": "sceneChanged"],
            ["type": "exportResult", "requestId": "r"],
            ["type": "exportFailed"],
            [String: Any](),
        ]
        for body in bodies {
            #expect(TerminalBlueprintBridgeMessage(body: body) == nil, "\(body)")
        }
    }
}
