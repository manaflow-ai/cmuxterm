import Foundation

/// The structural subset of an Excalidraw element the Swift-side blueprint
/// helpers read. Mirrors `webviews/src/blueprint/elementModel.ts` so the
/// summary an agent gets over the socket matches the one the canvas computes.
struct TerminalBlueprintSceneElement: Equatable, Sendable {
    var id: String
    var type: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isDeleted: Bool
    var text: String?
    var containerID: String?
    var startBindingID: String?
    var endBindingID: String?

    init(
        id: String,
        type: String,
        x: Double = 0,
        y: Double = 0,
        width: Double = 0,
        height: Double = 0,
        isDeleted: Bool = false,
        text: String? = nil,
        containerID: String? = nil,
        startBindingID: String? = nil,
        endBindingID: String? = nil
    ) {
        self.id = id
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isDeleted = isDeleted
        self.text = text
        self.containerID = containerID
        self.startBindingID = startBindingID
        self.endBindingID = endBindingID
    }

    /// Decodes one element object; nil when it lacks the id/type every
    /// Excalidraw element carries.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let type = json["type"] as? String else { return nil }
        self.init(
            id: id,
            type: type,
            x: Self.double(json["x"]) ?? 0,
            y: Self.double(json["y"]) ?? 0,
            width: Self.double(json["width"]) ?? 0,
            height: Self.double(json["height"]) ?? 0,
            isDeleted: (json["isDeleted"] as? Bool) ?? false,
            text: json["text"] as? String,
            containerID: json["containerId"] as? String,
            startBindingID: (json["startBinding"] as? [String: Any])?["elementId"] as? String,
            endBindingID: (json["endBinding"] as? [String: Any])?["elementId"] as? String
        )
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double, double.isFinite { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        return nil
    }
}

/// Pure helpers over a serialized Excalidraw scene: limits, element decoding,
/// the compact agent-facing summary, and the Swift fallback for `apply_ops`
/// when the canvas page is not live.
enum TerminalBlueprintScene {
    /// Largest scene JSON accepted over the socket.
    static let maxSceneBytes = 1_048_576
    /// Most live elements accepted in one scene.
    static let maxElements = 2_000
    /// Largest Mermaid source accepted for one render.
    static let maxMermaidBytes = 32_768
    /// Most operations accepted in one `apply_ops` call.
    static let maxOps = 500
    /// Lines the summary keeps before it says how many more there are.
    static let summaryLineCap = 200

    private static let connectorTypes: Set<String> = ["arrow", "line"]

    enum ValidationError: Error, Equatable {
        case notAnObject
        case missingElements
        case sceneTooLarge(bytes: Int)
        case tooManyElements(count: Int)
        case mermaidTooLarge(bytes: Int)
        case tooManyOps(count: Int)
        case invalidOp(index: Int, reason: String)
    }

    /// Checks size and shape limits of a scene an agent or the CLI sent.
    /// Returns the parsed top-level object so callers avoid a second parse.
    @discardableResult
    static func validateScene(_ sceneJSON: String) throws -> [String: Any] {
        let bytes = sceneJSON.utf8.count
        guard bytes <= maxSceneBytes else { throw ValidationError.sceneTooLarge(bytes: bytes) }
        let object = try parseObject(sceneJSON)
        let elements: [Any]
        if let list = object["elements"] as? [Any] {
            elements = list
        } else if let skeleton = object["skeleton"] as? [Any] {
            elements = skeleton
        } else {
            throw ValidationError.missingElements
        }
        guard elements.count <= maxElements else {
            throw ValidationError.tooManyElements(count: elements.count)
        }
        return object
    }

    static func validateMermaid(_ source: String) throws {
        let bytes = source.utf8.count
        guard bytes <= maxMermaidBytes else { throw ValidationError.mermaidTooLarge(bytes: bytes) }
    }

    /// Checks the shape of an `apply_ops` list: `{op: upsert, element}`,
    /// `{op: delete, id}`, or `{op: clear}`.
    static func validateOps(_ ops: [[String: Any]]) throws {
        guard ops.count <= maxOps else { throw ValidationError.tooManyOps(count: ops.count) }
        for (index, op) in ops.enumerated() {
            guard let kind = op["op"] as? String else {
                throw ValidationError.invalidOp(index: index, reason: "missing op")
            }
            switch kind {
            case "upsert":
                guard let element = op["element"] as? [String: Any],
                      let id = element["id"] as? String, !id.isEmpty else {
                    throw ValidationError.invalidOp(index: index, reason: "upsert needs an element with an id")
                }
            case "delete":
                guard let id = op["id"] as? String, !id.isEmpty else {
                    throw ValidationError.invalidOp(index: index, reason: "delete needs an id")
                }
            case "clear":
                break
            default:
                throw ValidationError.invalidOp(index: index, reason: "unknown op \(kind)")
            }
        }
    }

    // MARK: - Decoding

    static func elements(inSceneJSON sceneJSON: String) -> [TerminalBlueprintSceneElement] {
        guard let object = try? parseObject(sceneJSON),
              let list = object["elements"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap(TerminalBlueprintSceneElement.init(json:))
    }

    static func liveElementCount(inSceneJSON sceneJSON: String) -> Int {
        elements(inSceneJSON: sceneJSON).filter { !$0.isDeleted }.count
    }

    // MARK: - Summary

    static func summary(ofSceneJSON sceneJSON: String) -> String {
        summary(of: elements(inSceneJSON: sceneJSON))
    }

    /// Compact, LLM-friendly rendering of a scene: one line per live element,
    /// arrows as edges, freehand strokes collapsed into one line, capped at
    /// `summaryLineCap` lines. Port of `summarizeElements` in `summary.ts`.
    static func summary(of elements: [TerminalBlueprintSceneElement]) -> String {
        let live = elements.filter { !$0.isDeleted }
        guard !live.isEmpty else { return "(empty blueprint)" }

        let boundText = boundTextByContainer(live)
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let labeled = live.filter { $0.type != "freedraw" && !label(of: $0, boundText: boundText).isEmpty }

        var lines: [String] = []
        var strokes: [TerminalBlueprintSceneElement] = []
        for element in sortedByPosition(live) {
            if element.type == "freedraw" {
                strokes.append(element)
                continue
            }
            if element.type == "text", let containerID = element.containerID, byID[containerID] != nil {
                // Rendered as the container's label.
                continue
            }
            let elementLabel = label(of: element, boundText: boundText)
            if connectorTypes.contains(element.type) {
                let from = element.startBindingID.flatMap { byID[$0] != nil ? "#\(shortID($0))" : nil } ?? "?"
                let to = element.endBindingID.flatMap { byID[$0] != nil ? "#\(shortID($0))" : nil } ?? "?"
                let labelText = elementLabel.isEmpty ? "" : " \(quoted(elementLabel))"
                lines.append("#\(shortID(element.id)) \(element.type) \(from) -> \(to)\(labelText)")
                continue
            }
            if element.type == "text" {
                lines.append("#\(shortID(element.id)) text \(quoted(elementLabel))")
                continue
            }
            lines.append("#\(shortID(element.id)) \(element.type) \(quoted(elementLabel)) \(geometry(element))")
        }

        if !strokes.isEmpty {
            var nearestLabel = "unlabeled"
            var nearestDistance = Double.infinity
            for stroke in strokes {
                for candidate in labeled {
                    let distance = centerDistance(stroke, candidate)
                    if distance < nearestDistance {
                        nearestDistance = distance
                        nearestLabel = truncateLabel(label(of: candidate, boundText: boundText))
                    }
                }
            }
            let near = nearestLabel == "unlabeled"
                ? "unlabeled"
                : "\"\(nearestLabel.replacingOccurrences(of: "\"", with: "'"))\""
            lines.append("sketch: \(strokes.count) stroke\(strokes.count == 1 ? "" : "s") near \(near)")
        }

        if lines.count > summaryLineCap {
            let remaining = lines.count - summaryLineCap
            return (lines.prefix(summaryLineCap) + ["…and \(remaining) more"]).joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Ops fallback

    /// Applies `apply_ops` operations to a serialized scene without the canvas
    /// page. Used when the drawer's web view is not live; the page normalizes
    /// the result the next time it loads the scene.
    static func applyingOps(
        _ ops: [[String: Any]],
        toSceneJSON sceneJSON: String
    ) throws -> (sceneJSON: String, applied: Int) {
        try validateOps(ops)
        var object = try parseObject(sceneJSON)
        var elements = (object["elements"] as? [[String: Any]] ?? []).filter { ($0["isDeleted"] as? Bool) != true }
        var applied = 0
        for op in ops {
            switch op["op"] as? String {
            case "clear":
                elements = []
                applied += 1
            case "delete":
                let id = op["id"] as? String
                let before = elements.count
                elements.removeAll { ($0["id"] as? String) == id }
                if elements.count != before { applied += 1 }
            case "upsert":
                guard let element = op["element"] as? [String: Any], let id = element["id"] as? String else { continue }
                if let index = elements.firstIndex(where: { ($0["id"] as? String) == id }) {
                    elements[index] = element
                } else {
                    elements.append(element)
                }
                applied += 1
            default:
                continue
            }
        }
        object["elements"] = elements
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw ValidationError.notAnObject }
        return (json, applied)
    }

    // MARK: - Private

    private static func parseObject(_ sceneJSON: String) throws -> [String: Any] {
        guard let data = sceneJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            throw ValidationError.notAnObject
        }
        return object
    }

    private static func shortID(_ id: String) -> String {
        id.count <= 8 ? id : String(id.prefix(8))
    }

    private static func truncateLabel(_ text: String, maxLength: Int = 60) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }

    private static func quoted(_ text: String) -> String {
        "\"\(truncateLabel(text).replacingOccurrences(of: "\"", with: "'"))\""
    }

    /// JavaScript `Math.round` semantics (halves round toward positive infinity).
    private static func jsRound(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    private static func geometry(_ element: TerminalBlueprintSceneElement) -> String {
        "(\(jsRound(element.x)),\(jsRound(element.y)) \(jsRound(element.width))x\(jsRound(element.height)))"
    }

    private static func centerDistance(_ a: TerminalBlueprintSceneElement, _ b: TerminalBlueprintSceneElement) -> Double {
        let ax = a.x + a.width / 2
        let ay = a.y + a.height / 2
        let bx = b.x + b.width / 2
        let by = b.y + b.height / 2
        return hypot(ax - bx, ay - by)
    }

    private static func boundTextByContainer(_ elements: [TerminalBlueprintSceneElement]) -> [String: TerminalBlueprintSceneElement] {
        var byContainer: [String: TerminalBlueprintSceneElement] = [:]
        for element in elements {
            guard !element.isDeleted, element.type == "text", let containerID = element.containerID else { continue }
            if byContainer[containerID] == nil {
                byContainer[containerID] = element
            }
        }
        return byContainer
    }

    private static func label(
        of element: TerminalBlueprintSceneElement,
        boundText: [String: TerminalBlueprintSceneElement]
    ) -> String {
        if let bound = boundText[element.id]?.text, !bound.isEmpty {
            return bound
        }
        return element.text ?? ""
    }

    /// Deterministic reading order: top to bottom, then left to right.
    private static func sortedByPosition(_ elements: [TerminalBlueprintSceneElement]) -> [TerminalBlueprintSceneElement] {
        elements.sorted { a, b in
            if jsRound(a.y) != jsRound(b.y) { return a.y < b.y }
            if jsRound(a.x) != jsRound(b.x) { return a.x < b.x }
            return a.id < b.id
        }
    }
}
