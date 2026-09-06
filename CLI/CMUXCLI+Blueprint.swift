import Foundation

/// `cmux blueprint ...`: the CLI face of the per-terminal diagram canvas.
/// Every verb is one `blueprint.*` socket call; the target defaults to the
/// calling terminal (`CMUX_SURFACE_ID`) like the other surface commands.
extension CMUXCLI {
    static let blueprintUsage = """
    Usage: cmux blueprint <subcommand> [options]

    Read and draw the Blueprint canvas docked below a terminal
    (Settings › Beta Features › Blueprint must be on).

    Subcommands:
      state                       Drawer visibility, revision, element count, and a text summary
      get [--format summary|json|mermaid]
                                  Print the canvas in one format (default: summary)
      set [<scene.json>|-] [--base-revision N] [--source agent|user]
                                  Replace the scene with an Excalidraw scene (file, or JSON on stdin)
      mermaid [<file.mmd>|-] [--append] [--base-revision N]
                                  Render Mermaid into the canvas (file, or source on stdin)
      ops [<ops.json>|-] [--base-revision N]
                                  Apply targeted upsert/delete/clear operations (JSON array)
      export [--format png|svg|json|mermaid|summary] [--out <path>] [--scale N] [--dark]
                                  Save the canvas (PNG/SVG) or print a text format
      send [--formats png,mermaid,summary,json] [--prefix <text>] [--submit]
                                  Paste the canvas (PNG path and Mermaid by default) into the terminal prompt
      show | hide | collapse | expand [--focus true|false]
                                  Drawer visibility; show never moves focus unless --focus true
      mcp                         Run the cmux-blueprint MCP server on stdio (agent wrappers use this)

    Target options (all subcommands):
      --surface <id|ref|index>    Terminal whose blueprint to use (default: the calling terminal)
      --workspace <id|ref|index>  Workspace to resolve the surface in
      --window <id|ref|index>     Window to resolve the workspace in
      --auto-open true|false      set/mermaid/ops: open a closed drawer (default: the app setting)

    A stale --base-revision fails with `conflict`; run `cmux blueprint state`
    and retry with the current revision.

    Examples:
      cmux blueprint mermaid diagram.mmd
      echo 'flowchart LR; A-->B' | cmux blueprint mermaid -
      cmux blueprint export --format png --out docs/architecture.png
      cmux blueprint get --format summary
    """

    func runBlueprintNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.blueprintUsage)
            return
        }
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: "blueprint requires a subcommand. Try: state, get, set, mermaid, ops, export, send, show, hide, collapse, expand, mcp")
        }
        if sub == "mcp" {
            try runBlueprintMCPServer(socketPath: client.socketPath)
            return
        }
        let (params, rest) = try blueprintTargetParams(
            Array(commandArgs.dropFirst()),
            client: client,
            windowOverride: windowOverride
        )

        switch sub {
        case "state", "status":
            let payload = try client.sendV2(method: "blueprint.state", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: Self.blueprintStateText(payload))

        case "get", "read":
            var getParams = params
            let (formatOpt, rem) = parseOption(rest, name: "--format")
            try Self.blueprintRejectUnknownFlags(rem, sub: sub)
            if let formatOpt { getParams["format"] = formatOpt.lowercased() }
            let payload = try client.sendV2(method: "blueprint.get", params: getParams)
            let content = (payload["content"] as? String) ?? "(none)"
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: content)

        case "set":
            var setParams = params
            let (baseOpt, rem0) = parseOption(rest, name: "--base-revision")
            let (sourceOpt, rem1) = parseOption(rem0, name: "--source")
            let (positional, rem2) = Self.blueprintPositional(rem1)
            try Self.blueprintRejectUnknownFlags(rem2, sub: sub)
            let sceneText = try blueprintReadInput(positional, what: "scene JSON")
            guard let data = sceneText.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
                throw CLIError(message: "blueprint set: the scene must be a JSON object with an `elements` array")
            }
            setParams["scene"] = sceneText
            if let baseOpt { setParams["base_revision"] = try Self.blueprintRevision(baseOpt) }
            if let sourceOpt { setParams["source"] = sourceOpt.lowercased() }
            let payload = try client.sendV2(method: "blueprint.set", params: setParams)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: Self.blueprintMutationText(payload))

        case "mermaid", "render":
            var renderParams = params
            let (baseOpt, rem0) = parseOption(rest, name: "--base-revision")
            let (modeOpt, rem1) = parseOption(rem0, name: "--mode")
            var rem2 = rem1
            var mode = modeOpt?.lowercased() ?? "replace"
            if let index = rem2.firstIndex(of: "--append") {
                rem2.remove(at: index)
                mode = "append"
            }
            let (positional, rem3) = Self.blueprintPositional(rem2)
            try Self.blueprintRejectUnknownFlags(rem3, sub: sub)
            renderParams["mermaid"] = try blueprintReadInput(positional, what: "Mermaid source")
            renderParams["mode"] = mode
            if let baseOpt { renderParams["base_revision"] = try Self.blueprintRevision(baseOpt) }
            let payload = try client.sendV2(method: "blueprint.render_mermaid", params: renderParams)
            var text = Self.blueprintMutationText(payload)
            if let warnings = payload["warnings"] as? [String], !warnings.isEmpty {
                text += "\nwarnings: " + warnings.joined(separator: "; ")
            }
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: text)

        case "ops", "update":
            var opsParams = params
            let (baseOpt, rem0) = parseOption(rest, name: "--base-revision")
            let (positional, rem1) = Self.blueprintPositional(rem0)
            try Self.blueprintRejectUnknownFlags(rem1, sub: sub)
            let opsText = try blueprintReadInput(positional, what: "ops JSON")
            guard let data = opsText.data(using: .utf8),
                  let ops = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                throw CLIError(message: "blueprint ops: expected a JSON array of {\"op\": \"upsert\"|\"delete\"|\"clear\", ...} objects")
            }
            opsParams["ops"] = ops
            if let baseOpt { opsParams["base_revision"] = try Self.blueprintRevision(baseOpt) }
            let payload = try client.sendV2(method: "blueprint.apply_ops", params: opsParams)
            let applied = (payload["applied"] as? Int) ?? 0
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: Self.blueprintMutationText(payload) + " applied=\(applied)")

        case "export":
            var exportParams = params
            let (formatOpt, rem0) = parseOption(rest, name: "--format")
            let (outOpt, rem1) = parseOption(rem0, name: "--out")
            let (scaleOpt, rem2) = parseOption(rem1, name: "--scale")
            var rem3 = rem2
            if let index = rem3.firstIndex(of: "--dark") {
                rem3.remove(at: index)
                exportParams["dark"] = true
            }
            try Self.blueprintRejectUnknownFlags(rem3, sub: sub)
            let format = (formatOpt ?? "png").lowercased()
            exportParams["format"] = format
            if let outOpt { exportParams["path"] = resolvePath(outOpt) }
            if let scaleOpt {
                guard let scale = Double(scaleOpt), scale > 0 else {
                    throw CLIError(message: "--scale must be a positive number")
                }
                exportParams["scale"] = scale
            }
            let payload = try client.sendV2(method: "blueprint.export", params: exportParams)
            let text: String
            if let path = payload["path"] as? String {
                text = "OK format=\(format) path=\(path)"
            } else {
                text = (payload["content"] as? String) ?? ""
            }
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: text)

        case "send":
            var sendParams = params
            let (formatsOpt, rem0) = parseOption(rest, name: "--formats")
            let (prefixOpt, rem1) = parseOption(rem0, name: "--prefix")
            var rem2 = rem1
            if let index = rem2.firstIndex(of: "--submit") {
                rem2.remove(at: index)
                sendParams["submit"] = true
            }
            try Self.blueprintRejectUnknownFlags(rem2, sub: sub)
            if let formatsOpt {
                sendParams["formats"] = formatsOpt.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
            if let prefixOpt { sendParams["prompt_prefix"] = prefixOpt }
            let payload = try client.sendV2(method: "blueprint.send_to_terminal", params: sendParams)
            let formats = (payload["formats"] as? [String])?.joined(separator: ",") ?? ""
            let length = (payload["text_length"] as? Int) ?? 0
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK sent formats=\(formats) chars=\(length)")

        case "show", "open", "hide", "close", "collapse", "expand", "toggle":
            var verbParams = params
            let (focusOpt, rem) = parseOption(rest, name: "--focus")
            try Self.blueprintRejectUnknownFlags(rem, sub: sub)
            try applyFocusOption(focusOpt, defaultValue: false, to: &verbParams)
            let method: String
            switch sub {
            case "show", "open": method = "blueprint.show"
            case "hide", "close": method = "blueprint.hide"
            case "collapse": method = "blueprint.collapse"
            case "expand": method = "blueprint.expand"
            default:
                // toggle: one state read decides which verb applies.
                let state = try client.sendV2(method: "blueprint.state", params: params)
                method = (state["visible"] as? Bool) == true ? "blueprint.hide" : "blueprint.show"
            }
            let payload = try client.sendV2(method: method, params: verbParams)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: Self.blueprintStateText(payload, includeSummary: false))

        default:
            throw CLIError(message: "Unknown blueprint subcommand: \(sub). Run 'cmux blueprint --help' for usage.")
        }
    }

    // MARK: - Helpers

    /// Routing params shared by every verb. The surface defaults to the
    /// caller's terminal unless a workspace or window was named explicitly.
    private func blueprintTargetParams(
        _ args: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> (params: [String: Any], rest: [String]) {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        let (windowOpt, rem1) = parseOption(rem0, name: "--window")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (autoOpenOpt, rem3) = parseOption(rem2, name: "--auto-open")
        var params: [String: Any] = [:]
        let windowRaw = windowOpt ?? windowOverride
        let environment = ProcessInfo.processInfo.environment
        let surfaceRaw = surfaceOpt ?? (workspaceOpt == nil && windowRaw == nil ? environment["CMUX_SURFACE_ID"] : nil)
        if let surfaceRaw, let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
            params["surface_id"] = surface
        }
        let workspaceRaw = workspaceOpt ?? (windowRaw == nil ? environment["CMUX_WORKSPACE_ID"] : nil)
        if let workspaceRaw, let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
            params["workspace_id"] = workspace
        }
        if let windowRaw, let window = try normalizeWindowHandle(windowRaw, client: client) {
            params["window_id"] = window
        }
        if let autoOpenOpt {
            guard let autoOpen = parseBoolString(autoOpenOpt) else {
                throw CLIError(message: "--auto-open must be true|false")
            }
            params["auto_open"] = autoOpen
        }
        return (params, rem3)
    }

    /// The first non-flag argument, removed from the list.
    private static func blueprintPositional(_ args: [String]) -> (String?, [String]) {
        guard let index = args.firstIndex(where: { !$0.hasPrefix("-") || $0 == "-" }) else { return (nil, args) }
        var rest = args
        let value = rest.remove(at: index)
        return (value, rest)
    }

    private static func blueprintRejectUnknownFlags(_ args: [String], sub: String) throws {
        if let flag = args.first(where: { $0.hasPrefix("-") && $0 != "-" }) {
            throw CLIError(message: "blueprint \(sub): unknown flag '\(flag)'. Run 'cmux blueprint --help' for usage.")
        }
        if let extra = args.first {
            throw CLIError(message: "blueprint \(sub): unexpected argument '\(extra)'")
        }
    }

    private static func blueprintRevision(_ raw: String) throws -> Int {
        guard let value = Int(raw), value >= 0 else {
            throw CLIError(message: "--base-revision must be a non-negative integer")
        }
        return value
    }

    /// Reads a positional file (or stdin for `-` / no argument).
    private func blueprintReadInput(_ positional: String?, what: String) throws -> String {
        if let positional, positional != "-" {
            let path = resolvePath(positional)
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "Could not read \(what) from \(path)")
            }
            return text
        }
        guard isatty(STDIN_FILENO) == 0 else {
            throw CLIError(message: "Pass a file path, or pipe the \(what) on stdin (use '-' to read stdin explicitly)")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "No \(what) was provided on stdin")
        }
        return text
    }

    static func blueprintStateText(_ payload: [String: Any], includeSummary: Bool = true) -> String {
        let revision = (payload["revision"] as? Int) ?? 0
        let count = (payload["element_count"] as? Int) ?? 0
        let visible = (payload["visible"] as? Bool) == true
        let collapsed = (payload["collapsed"] as? Bool) == true
        let updatedBy = (payload["updated_by"] as? String) ?? "user"
        var drawer = visible ? "visible" : "hidden"
        if visible, collapsed { drawer = "collapsed" }
        var lines = ["revision=\(revision) elements=\(count) drawer=\(drawer) updated_by=\(updatedBy)"]
        if includeSummary, let summary = payload["summary"] as? String, !summary.isEmpty {
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    static func blueprintMutationText(_ payload: [String: Any]) -> String {
        let revision = (payload["revision"] as? Int) ?? 0
        let count = (payload["element_count"] as? Int) ?? 0
        return "OK revision=\(revision) elements=\(count)"
    }
}
