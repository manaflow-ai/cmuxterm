import Foundation

/// Supplies authoritative delivery ownership for the Codex hook socket fixture.
struct CodexHookSocketResponseFixture {
    let workspaceId: String
    let surfaceId: String

    func response(for line: String) -> String {
        guard let payload = codexHookJSONObject(line),
              let id = payload["id"] as? String else {
            return "OK"
        }
        let method = payload["method"] as? String
        let params = payload["params"] as? [String: Any] ?? [:]
        if method == "surface.list" {
            return codexHookV2Response(
                id: id,
                ok: true,
                result: ["surfaces": [["id": surfaceId, "ref": surfaceId, "focused": true]]]
            )
        }
        if method == "agent.resolve_delivery_target" {
            if let requestedWorkspace = params["workspace_id"] as? String, requestedWorkspace != workspaceId {
                return codexHookV2Response(id: id, ok: false)
            }
            if params["pid"] != nil {
                guard hasPositivePID(params["pid"]) else {
                    return codexHookV2Response(id: id, ok: false)
                }
                return codexHookV2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": surfaceId, "source": "pid",
                             "pid_resolution": "corroborated"]
                )
            }
            if let requestedSurface = params["surface_id"] as? String {
                guard requestedSurface == surfaceId else {
                    return codexHookV2Response(id: id, ok: false)
                }
                return codexHookV2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": surfaceId, "source": "surface"]
                )
            }
            if params["workspace_id"] != nil {
                return codexHookV2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": NSNull(), "source": "workspace"]
                )
            }
            return codexHookV2Response(id: id, ok: false)
        }
        return codexHookV2Response(id: id, ok: true, result: [:])
    }

    private func hasPositivePID(_ raw: Any?) -> Bool {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let value = number.doubleValue
            return value.isFinite && floor(value) == value && Int(exactly: value).map { $0 > 0 } == true
        }
        if let integer = raw as? Int {
            return integer > 0
        }
        if let string = raw as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 > 0 } == true
        }
        return false
    }
}
