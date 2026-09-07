public import Foundation

/// A bounded, fully validated sequence of v2 RPC requests.
///
/// Parameters may contain `{"$ref":"request-id#/json/pointer"}` to substitute
/// a value from an earlier result. Validation never performs I/O or executes RPCs.
public struct CmuxRPCBatchPlan {
    /// Maximum encoded input size, enforced before JSON parsing.
    public static let maximumInputBytes = 1_048_576
    /// Maximum number of requests in a plan.
    public static let maximumRequests = 256
    /// Maximum JSON container nesting depth, including reference parameters.
    public static let maximumDepth = 64

    /// One validated request, with parameters still containing any references.
    public struct Request {
        /// A unique identifier used by later references and output records.
        public let id: String
        /// The v2 method to invoke.
        public let method: String
        /// Parameters that will be resolved immediately before execution.
        public let params: [String: Any]
    }

    /// Requests in their execution order.
    public let requests: [Request]

    /// Validates all requests and reference targets before execution can begin.
    /// - Parameter data: A UTF-8 JSON array of objects with `id`, `method`, and optional `params`.
    /// - Throws: ``CmuxRPCBatchError`` if any part of the plan is invalid.
    public init(data: Data) throws {
        guard data.count <= Self.maximumInputBytes else { throw CmuxRPCBatchError(.inputLimit) }
        try Self.validateDepth(data)
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let items = raw as? [[String: Any]], !items.isEmpty else {
            throw CmuxRPCBatchError(.invalidPlan)
        }
        guard items.count <= Self.maximumRequests else { throw CmuxRPCBatchError(.requestLimit) }
        var ids = Set<String>()
        var requests: [Request] = []
        for (index, item) in items.enumerated() {
            guard Set(item.keys).isSubset(of: ["id", "method", "params"]),
                  let method = item["method"] as? String,
                  !method.isEmpty, method.utf8.count <= 128,
                  method.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._").contains($0)
                  }),
                  item["params"] == nil || item["params"] is [String: Any] else {
                throw CmuxRPCBatchError(.invalidPlan, index: index)
            }
            guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  id.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
                  }), !ids.contains(id) else {
                throw CmuxRPCBatchError(.invalidID, index: index)
            }
            // Streaming and authentication change the connection's protocol/state.
            guard method.lowercased() != "events.stream",
                  !method.lowercased().hasPrefix("auth.") else {
                throw CmuxRPCBatchError(.unsupportedMethod, index: index)
            }
            let params = item["params"] as? [String: Any] ?? [:]
            try Self.validateReferences(params, earlierIDs: ids, index: index)
            requests.append(Request(id: id, method: method, params: params))
            ids.insert(id)
        }
        self.requests = requests
    }

    private static func validateDepth(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true
            } else if byte == 91 || byte == 123 {
                depth += 1
                if depth > maximumDepth { throw CmuxRPCBatchError(.inputLimit) }
            } else if byte == 93 || byte == 125 {
                depth -= 1
            }
        }
    }

    private static func validateReferences(_ value: Any, earlierIDs: Set<String>, index: Int) throws {
        if let object = value as? [String: Any] {
            if object["$ref"] != nil {
                guard object.count == 1, let ref = object["$ref"] as? String,
                      let (id, _) = referenceParts(ref), earlierIDs.contains(id) else {
                    throw CmuxRPCBatchError(.invalidReference, index: index)
                }
            } else {
                for child in object.values { try validateReferences(child, earlierIDs: earlierIDs, index: index) }
            }
        } else if let array = value as? [Any] {
            for child in array { try validateReferences(child, earlierIDs: earlierIDs, index: index) }
        }
    }

    /// Parses JSON Pointer escapes without URL decoding or string interpolation.
    static func referenceParts(_ ref: String) -> (String, [String])? {
        guard let hash = ref.firstIndex(of: "#") else { return nil }
        let id = String(ref[..<hash])
        let pointer = String(ref[ref.index(after: hash)...])
        if pointer.isEmpty { return (id, []) }
        guard pointer.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for token in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            var decoded = ""
            var cursor = token.startIndex
            while cursor < token.endIndex {
                let char = token[cursor]
                cursor = token.index(after: cursor)
                if char == "~" {
                    guard cursor < token.endIndex else { return nil }
                    switch token[cursor] {
                    case "0": decoded.append("~")
                    case "1": decoded.append("/")
                    default: return nil
                    }
                    cursor = token.index(after: cursor)
                } else { decoded.append(char) }
            }
            parts.append(decoded)
        }
        return (id, parts)
    }

    func resolve(_ value: Any, results: [String: [String: Any]], index: Int) throws -> Any {
        if let object = value as? [String: Any] {
            if let ref = object["$ref"] as? String, let (id, path) = Self.referenceParts(ref) {
                guard let result = results[id] else { throw CmuxRPCBatchError(.unresolvedReference, index: index) }
                var current: Any = result
                for component in path {
                    if let dictionary = current as? [String: Any], let next = dictionary[component] {
                        current = next
                    } else if let array = current as? [Any],
                              component == "0" || (!component.hasPrefix("0") && !component.isEmpty),
                              component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                              let offset = Int(component), array.indices.contains(offset) {
                        current = array[offset]
                    } else { throw CmuxRPCBatchError(.unresolvedReference, index: index) }
                }
                return current
            }
            return try object.mapValues { try resolve($0, results: results, index: index) }
        }
        if let array = value as? [Any] {
            return try array.map { try resolve($0, results: results, index: index) }
        }
        return value
    }
}
