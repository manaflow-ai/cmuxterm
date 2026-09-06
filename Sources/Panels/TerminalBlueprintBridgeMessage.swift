import Foundation

/// A message the blueprint web page posts to Swift through the `cmuxBlueprint`
/// script message handler.
enum TerminalBlueprintBridgeMessage: Equatable, Sendable {
    case ready
    case sceneChanged(sceneJSON: String, elementCount: Int, digest: String)
    case exportResult(TerminalBlueprintExportResult)
    case exportFailed(requestID: String, message: String)
    case requestTerminalFocus
    case error(message: String)

    /// Decodes the JSON object the page posted. Returns nil for unknown or
    /// malformed messages so a page bug never crashes the app.
    init?(body: Any) {
        guard let object = body as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "ready":
            self = .ready
        case "sceneChanged":
            guard let sceneJSON = object["sceneJSON"] as? String else { return nil }
            let elementCount = Self.integer(object["elementCount"]) ?? 0
            let digest = object["digest"] as? String ?? ""
            self = .sceneChanged(sceneJSON: sceneJSON, elementCount: elementCount, digest: digest)
        case "exportResult":
            guard let requestID = object["requestId"] as? String,
                  let sceneJSON = object["sceneJSON"] as? String else {
                return nil
            }
            self = .exportResult(TerminalBlueprintExportResult(
                requestID: requestID,
                pngBase64: object["pngBase64"] as? String,
                svg: object["svg"] as? String,
                mermaid: object["mermaid"] as? String,
                sceneJSON: sceneJSON,
                width: Self.double(object["width"]) ?? 0,
                height: Self.double(object["height"]) ?? 0
            ))
        case "exportFailed":
            guard let requestID = object["requestId"] as? String else { return nil }
            self = .exportFailed(
                requestID: requestID,
                message: object["message"] as? String ?? ""
            )
        case "requestTerminalFocus":
            self = .requestTerminalFocus
        case "error":
            self = .error(message: object["message"] as? String ?? "")
        default:
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

/// The result of one `requestExport` round trip with the web canvas.
struct TerminalBlueprintExportResult: Equatable, Sendable {
    var requestID: String
    var pngBase64: String?
    var svg: String?
    var mermaid: String?
    var sceneJSON: String
    var width: Double
    var height: Double

    var pngData: Data? {
        pngBase64.flatMap { Data(base64Encoded: $0) }
    }
}
