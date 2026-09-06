import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalBlueprintScene")
struct TerminalBlueprintSceneTests {
    private func scene(_ elements: [[String: Any]]) -> String {
        let object: [String: Any] = ["type": "excalidraw", "version": 2, "elements": elements, "appState": [:], "files": [:]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func box(_ id: String, _ text: String, x: Double, y: Double) -> [[String: Any]] {
        [
            ["id": id, "type": "rectangle", "x": x, "y": y, "width": 200, "height": 80, "boundElements": [["id": "\(id)-t", "type": "text"]]],
            ["id": "\(id)-t", "type": "text", "x": x + 10, "y": y + 10, "width": 100, "height": 20, "text": text, "containerId": id],
        ]
    }

    @Test func emptySceneSummarizesAsEmpty() {
        #expect(TerminalBlueprintScene.summary(ofSceneJSON: TerminalBlueprintState.emptySceneJSON) == "(empty blueprint)")
        #expect(TerminalBlueprintScene.summary(ofSceneJSON: "not json") == "(empty blueprint)")
    }

    @Test func summaryMatchesTheCanvasFormat() {
        // Matches `summarizeElements` in webviews/src/blueprint/summary.ts:
        // reading order, bound text as labels, arrows as edges, strokes collapsed.
        var elements = box("api00001", "API Gateway", x: 0, y: 0) + box("db000001", "Postgres", x: 0, y: 200)
        elements.append([
            "id": "arrow001", "type": "arrow", "x": 100, "y": 80, "width": 0, "height": 120,
            "startBinding": ["elementId": "api00001"], "endBinding": ["elementId": "db000001"],
        ])
        elements.append(["id": "note0001", "type": "text", "x": 300, "y": 0, "width": 80, "height": 20, "text": "todo: \"cache\"  layer"])
        elements.append(["id": "stroke01", "type": "freedraw", "x": 20, "y": 210, "width": 40, "height": 10])
        elements.append(["id": "gone0001", "type": "ellipse", "x": 0, "y": 500, "width": 10, "height": 10, "isDeleted": true])

        let summary = TerminalBlueprintScene.summary(ofSceneJSON: scene(elements))

        #expect(summary == """
        #api00001 rectangle "API Gateway" (0,0 200x80)
        #note0001 text "todo: 'cache' layer"
        #arrow001 arrow #api00001 -> #db000001
        #db000001 rectangle "Postgres" (0,200 200x80)
        sketch: 1 stroke near "Postgres"
        """)
    }

    @Test func summaryCapsLongScenes() {
        var elements: [[String: Any]] = []
        for index in 0..<250 {
            elements.append(["id": String(format: "e%07d", index), "type": "rectangle", "x": 0, "y": Double(index * 10), "width": 10, "height": 5, "text": ""])
        }
        let lines = TerminalBlueprintScene.summary(ofSceneJSON: scene(elements)).split(separator: "\n")
        #expect(lines.count == TerminalBlueprintScene.summaryLineCap + 1)
        #expect(lines.last == "…and 50 more")
    }

    @Test func liveElementCountIgnoresDeleted() {
        let json = scene(box("a0000001", "A", x: 0, y: 0) + [["id": "x", "type": "rectangle", "isDeleted": true]])
        #expect(TerminalBlueprintScene.liveElementCount(inSceneJSON: json) == 2)
    }

    @Test func validateSceneEnforcesShapeAndLimits() throws {
        _ = try TerminalBlueprintScene.validateScene(scene([]))
        _ = try TerminalBlueprintScene.validateScene(#"{"skeleton":[{"type":"rectangle"}]}"#)
        #expect(throws: TerminalBlueprintScene.ValidationError.notAnObject) {
            try TerminalBlueprintScene.validateScene("[1,2]")
        }
        #expect(throws: TerminalBlueprintScene.ValidationError.missingElements) {
            try TerminalBlueprintScene.validateScene(#"{"appState":{}}"#)
        }
        let big = String(repeating: "x", count: TerminalBlueprintScene.maxSceneBytes + 1)
        #expect(throws: TerminalBlueprintScene.ValidationError.sceneTooLarge(bytes: big.utf8.count)) {
            try TerminalBlueprintScene.validateScene(big)
        }
        let many = (0...TerminalBlueprintScene.maxElements).map { ["id": "\($0)", "type": "rectangle"] as [String: Any] }
        #expect(throws: TerminalBlueprintScene.ValidationError.tooManyElements(count: many.count)) {
            try TerminalBlueprintScene.validateScene(scene(many))
        }
        #expect(throws: TerminalBlueprintScene.ValidationError.mermaidTooLarge(bytes: TerminalBlueprintScene.maxMermaidBytes + 1)) {
            try TerminalBlueprintScene.validateMermaid(String(repeating: "a", count: TerminalBlueprintScene.maxMermaidBytes + 1))
        }
    }

    @Test func validateOpsRejectsMalformedOperations() {
        #expect(throws: TerminalBlueprintScene.ValidationError.invalidOp(index: 0, reason: "missing op")) {
            try TerminalBlueprintScene.validateOps([["element": ["id": "a"]]])
        }
        #expect(throws: TerminalBlueprintScene.ValidationError.invalidOp(index: 0, reason: "upsert needs an element with an id")) {
            try TerminalBlueprintScene.validateOps([["op": "upsert", "element": ["type": "rectangle"]]])
        }
        #expect(throws: TerminalBlueprintScene.ValidationError.invalidOp(index: 1, reason: "delete needs an id")) {
            try TerminalBlueprintScene.validateOps([["op": "clear"], ["op": "delete"]])
        }
        #expect(throws: TerminalBlueprintScene.ValidationError.invalidOp(index: 0, reason: "unknown op move")) {
            try TerminalBlueprintScene.validateOps([["op": "move"]])
        }
        let tooMany = Array(repeating: ["op": "clear"] as [String: Any], count: TerminalBlueprintScene.maxOps + 1)
        #expect(throws: TerminalBlueprintScene.ValidationError.tooManyOps(count: tooMany.count)) {
            try TerminalBlueprintScene.validateOps(tooMany)
        }
    }

    @Test func applyingOpsWithoutTheCanvasUpsertsDeletesAndClears() throws {
        let json = scene(box("a0000001", "A", x: 0, y: 0) + box("b0000001", "B", x: 0, y: 100))

        let result = try TerminalBlueprintScene.applyingOps([
            ["op": "upsert", "element": ["id": "a0000001", "type": "rectangle", "x": 50, "y": 0, "width": 200, "height": 80]],
            ["op": "upsert", "element": ["id": "c0000001", "type": "ellipse", "x": 0, "y": 300, "width": 40, "height": 40]],
            ["op": "delete", "id": "b0000001"],
            ["op": "delete", "id": "missing"],
        ], toSceneJSON: json)

        #expect(result.applied == 3)
        let elements = TerminalBlueprintScene.elements(inSceneJSON: result.sceneJSON)
        #expect(elements.map(\.id).sorted() == ["a0000001", "a0000001-t", "b0000001-t", "c0000001"])
        #expect(elements.first { $0.id == "a0000001" }?.x == 50)

        let cleared = try TerminalBlueprintScene.applyingOps([["op": "clear"]], toSceneJSON: result.sceneJSON)
        #expect(cleared.applied == 1)
        #expect(TerminalBlueprintScene.liveElementCount(inSceneJSON: cleared.sceneJSON) == 0)
    }
}
