import Foundation

extension CMUXCLI {
    /// `cmux blueprint mcp`: serves the `cmux-blueprint` MCP server on stdio
    /// until stdin closes. Each tool call is one `blueprint.*` socket call
    /// bound to the terminal the agent runs in (`CMUX_SURFACE_ID`).
    func runBlueprintMCPServer(socketPath: String) throws {
        let server = BlueprintMCPServer(
            environment: ProcessInfo.processInfo.environment,
            version: Self.cliVersionString()
        ) { method, params in
            // One connection per call: the server starts before cmux is up and
            // keeps working across a cmux restart.
            let client = SocketClient(path: socketPath)
            try client.connect()
            defer { client.close() }
            return try client.sendV2(method: method, params: params)
        }
        server.serve()
    }

    static func cliVersionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

/// A minimal Model Context Protocol server (newline-delimited JSON-RPC 2.0 on
/// stdio) exposing the blueprint canvas as tools. It never reads the socket
/// for `initialize` or `tools/list`, so agent hosts that wait on discovery
/// before the first turn (Codex) start immediately even when cmux is busy.
final class BlueprintMCPServer {
    static let serverName = "cmux-blueprint"
    static let protocolVersion = "2024-11-05"
    static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    static let instructions = """
    The user has a Blueprint diagram canvas docked below this terminal. Keep it a current, minimal \
    blueprint of the system you are designing: redraw with blueprint_show_mermaid when the architecture \
    or data flow changes, not on every file edit, and keep diagrams under about 40 nodes. Call \
    blueprint_state first to get the revision; if updated_by is "user", read their sketch with \
    blueprint_get before drawing over it. A "conflict" error means the canvas changed since your \
    base_revision: read it again and retry.
    """

    typealias SocketCall = (_ method: String, _ params: [String: Any]) throws -> [String: Any]

    private let call: SocketCall
    private let surfaceID: String?
    private let workspaceID: String?
    private let version: String
    private let stdout = FileHandle.standardOutput

    init(environment: [String: String], version: String, call: @escaping SocketCall) {
        self.call = call
        self.surfaceID = environment["CMUX_SURFACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        self.workspaceID = environment["CMUX_WORKSPACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        self.version = version
    }

    func serve() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            handleLine(trimmed)
        }
    }

    func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            write(Self.errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }
        if let batch = parsed as? [[String: Any]] {
            let responses = batch.compactMap(handleMessage)
            if !responses.isEmpty { write(responses) }
            return
        }
        guard let message = parsed as? [String: Any] else {
            write(Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid request"))
            return
        }
        if let response = handleMessage(message) {
            write(response)
        }
    }

    /// Returns the response object, or nil for notifications.
    func handleMessage(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            guard let id else { return nil }
            return Self.errorResponse(id: id, code: -32600, message: "Missing method")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let isNotification = id == nil || id is NSNull
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let negotiated = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersion
            return Self.result(id: id, [
                "protocolVersion": negotiated,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.toolDefinitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.errorResponse(id: id ?? NSNull(), code: -32602, message: "tools/call needs a name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return Self.result(id: id, callTool(name: name, arguments: arguments))
        default:
            if isNotification || method.hasPrefix("notifications/") {
                return nil
            }
            return Self.errorResponse(id: id ?? NSNull(), code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let toolDefinitions: [[String: Any]] = [
        tool(
            "blueprint_state",
            "Cheap. Reports the canvas next to this terminal: revision, element count, whether the drawer is visible, who edited it last, and a compact text summary. Call it before editing to get `revision`.",
            properties: [:]
        ),
        tool(
            "blueprint_show_mermaid",
            "Preferred way to draw. Renders a Mermaid diagram (flowchart, sequence, class, state, ER) into the user's Blueprint canvas beside this terminal. Use mode `replace` for the whole architecture and `append` to add a sub-diagram below what is there. Keep it under about 40 nodes.",
            properties: [
                "mermaid": ["type": "string", "description": "Mermaid source, for example `flowchart LR\\n  API --> DB`."],
                "mode": ["type": "string", "enum": ["replace", "append"], "description": "replace (default) or append below the current drawing."],
                "base_revision": ["type": "integer", "description": "The revision you last read. Fails with `conflict` if the user edited since."],
            ],
            required: ["mermaid"]
        ),
        tool(
            "blueprint_get",
            "Reads what is on the canvas, including the user's own sketches. `summary` (default) is compact text, one line per element with arrows as edges; `mermaid` is the last Mermaid source drawn, if any; `json` is the raw Excalidraw scene and can be large.",
            properties: [
                "format": ["type": "string", "enum": ["summary", "mermaid", "json"], "description": "Default summary."],
            ]
        ),
        tool(
            "blueprint_update",
            "Targeted edits to existing elements: `upsert` an Excalidraw element (by id), `delete` by id, or `clear` everything. Fails with `conflict` if the canvas changed since `base_revision`; read it again and retry.",
            properties: [
                "ops": [
                    "type": "array",
                    "description": "Operations in order.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "op": ["type": "string", "enum": ["upsert", "delete", "clear"]],
                            "element": ["type": "object", "description": "For upsert: an Excalidraw element with an `id`."],
                            "id": ["type": "string", "description": "For delete: the element id."],
                        ],
                        "required": ["op"],
                    ],
                ],
                "base_revision": ["type": "integer"],
            ],
            required: ["ops"]
        ),
        tool(
            "blueprint_set_scene",
            "Replaces the whole canvas with Excalidraw elements. Prefer blueprint_show_mermaid; use this only when you need exact shapes and positions.",
            properties: [
                "elements": ["type": "array", "description": "Excalidraw elements.", "items": ["type": "object"]],
                "base_revision": ["type": "integer"],
            ],
            required: ["elements"]
        ),
        tool(
            "blueprint_export_image",
            "Saves the diagram to disk as PNG or SVG (for example into the repository's docs/) and returns the path.",
            properties: [
                "format": ["type": "string", "enum": ["png", "svg"], "description": "Default png."],
                "path": ["type": "string", "description": "Absolute output path. Without it the file is written next to the stored blueprint."],
                "scale": ["type": "number", "description": "Pixel scale for PNG, default 2."],
            ]
        ),
        tool(
            "blueprint_show",
            "Opens the Blueprint drawer below this terminal so the user sees it. Never moves keyboard focus.",
            properties: [:]
        ),
        tool(
            "blueprint_hide",
            "Hides the Blueprint drawer. The drawing is kept.",
            properties: [:]
        ),
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        guard let surfaceID else {
            return Self.toolError("Not running inside a cmux terminal: CMUX_SURFACE_ID is not set, so there is no Blueprint canvas to draw on.")
        }
        var params: [String: Any] = ["surface_id": surfaceID]
        if let workspaceID { params["workspace_id"] = workspaceID }

        let method: String
        switch name {
        case "blueprint_state":
            method = "blueprint.state"
        case "blueprint_show_mermaid":
            guard let mermaid = arguments["mermaid"] as? String, !mermaid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.toolError("blueprint_show_mermaid needs a non-empty `mermaid` string.")
            }
            method = "blueprint.render_mermaid"
            params["mermaid"] = mermaid
            params["mode"] = (arguments["mode"] as? String) ?? "replace"
            if let base = Self.integer(arguments["base_revision"]) { params["base_revision"] = base }
        case "blueprint_get":
            method = "blueprint.get"
            params["format"] = (arguments["format"] as? String) ?? "summary"
        case "blueprint_update":
            guard let ops = arguments["ops"] as? [[String: Any]] else {
                return Self.toolError("blueprint_update needs an `ops` array.")
            }
            method = "blueprint.apply_ops"
            params["ops"] = ops
            if let base = Self.integer(arguments["base_revision"]) { params["base_revision"] = base }
        case "blueprint_set_scene":
            guard let elements = arguments["elements"] as? [Any] else {
                return Self.toolError("blueprint_set_scene needs an `elements` array.")
            }
            method = "blueprint.set"
            params["scene"] = [
                "type": "excalidraw",
                "version": 2,
                "source": "cmux-blueprint",
                "elements": elements,
                "appState": [String: Any](),
                "files": [String: Any](),
            ] as [String: Any]
            if let base = Self.integer(arguments["base_revision"]) { params["base_revision"] = base }
        case "blueprint_export_image":
            method = "blueprint.export"
            params["format"] = (arguments["format"] as? String) ?? "png"
            if let path = arguments["path"] as? String, !path.isEmpty { params["path"] = path }
            if let scale = arguments["scale"] as? Double { params["scale"] = scale }
        case "blueprint_show":
            method = "blueprint.show"
        case "blueprint_hide":
            method = "blueprint.hide"
        default:
            return Self.toolError("Unknown tool: \(name)")
        }

        do {
            let payload = try call(method, params)
            return Self.toolText(Self.render(method: method, payload: payload))
        } catch let error as CLIError {
            return Self.toolError(Self.describe(error, method: method))
        } catch {
            return Self.toolError("\(error)")
        }
    }

    // MARK: - Rendering

    private static func render(method: String, payload: [String: Any]) -> String {
        switch method {
        case "blueprint.state", "blueprint.show", "blueprint.hide":
            var lines: [String] = []
            let revision = integer(payload["revision"]) ?? 0
            let count = integer(payload["element_count"]) ?? 0
            let visible = (payload["visible"] as? Bool) == true
            let updatedBy = (payload["updated_by"] as? String) ?? "user"
            lines.append("revision: \(revision)")
            lines.append("elements: \(count)")
            lines.append("drawer: \(visible ? "visible" : "hidden")")
            lines.append("updated_by: \(updatedBy)")
            if (payload["unseen_agent_update"] as? Bool) == true {
                lines.append("note: the user has not looked at your last update yet")
            }
            if method == "blueprint.state", let summary = payload["summary"] as? String, !summary.isEmpty {
                lines.append("")
                lines.append(summary)
            }
            return lines.joined(separator: "\n")
        case "blueprint.get":
            let format = (payload["format"] as? String) ?? "summary"
            let revision = integer(payload["revision"]) ?? 0
            guard let content = payload["content"] as? String else {
                return "revision: \(revision)\n(no \(format) content; nothing has been drawn with Mermaid yet)"
            }
            return "revision: \(revision)\nformat: \(format)\n\n\(content)"
        case "blueprint.export":
            if let path = payload["path"] as? String {
                var line = "Saved \(path)"
                if let width = payload["width"] as? Double, let height = payload["height"] as? Double, width > 0 {
                    line += " (\(Int(width))x\(Int(height)))"
                }
                return line
            }
            return (payload["content"] as? String) ?? "OK"
        default:
            let revision = integer(payload["revision"]) ?? 0
            let count = integer(payload["element_count"]) ?? 0
            var line = "OK: revision \(revision), \(count) element\(count == 1 ? "" : "s")"
            if let applied = integer(payload["applied"]) { line += ", \(applied) op\(applied == 1 ? "" : "s") applied" }
            if let warnings = payload["warnings"] as? [String], !warnings.isEmpty {
                line += "\nwarnings: " + warnings.joined(separator: "; ")
            }
            if (payload["visible"] as? Bool) == false {
                line += "\n(the drawer is hidden; the user will see an \"updated by agent\" badge when they open it)"
            }
            return line
        }
    }

    private static func describe(_ error: CLIError, method: String) -> String {
        switch error.v2Code {
        case "method_not_found":
            return "Blueprint is not available in this cmux: turn it on in Settings › Beta Features › Blueprint, or update cmux."
        case "conflict":
            return "\(error.message)\nRead the canvas again with blueprint_state or blueprint_get and retry with the current revision."
        default:
            return error.message
        }
    }

    // MARK: - JSON-RPC plumbing

    private static func result(id: Any?, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func toolText(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private static func toolError(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func write(_ object: Any) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return
        }
        stdout.write(data)
        stdout.write(Data("\n".utf8))
    }
}
