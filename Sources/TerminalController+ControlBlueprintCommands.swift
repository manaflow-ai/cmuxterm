import CmuxControlSocket
import Foundation

/// The blueprint verbs that wait on the canvas page: `blueprint.set`,
/// `blueprint.apply_ops`, `blueprint.render_mermaid`, `blueprint.export`, and
/// `blueprint.send_to_terminal`. They run on the socket worker lane (see
/// `ControlCommandExecutionPolicy`) and hop to the main actor for the model
/// work, awaiting the page without holding the main thread.
extension TerminalController {
    nonisolated static let v2BlueprintCanvasMethods: Set<String> = [
        "blueprint.set",
        "blueprint.apply_ops",
        "blueprint.render_mermaid",
        "blueprint.export",
        "blueprint.send_to_terminal",
    ]

    nonisolated static let v2BlueprintMainActorMethods: [String] = [
        "blueprint.state",
        "blueprint.get",
        "blueprint.show",
        "blueprint.hide",
        "blueprint.collapse",
        "blueprint.expand",
    ]

    /// Every `blueprint.*` method, for the capabilities list.
    nonisolated static var v2BlueprintMethods: [String] {
        v2BlueprintMainActorMethods + v2BlueprintCanvasMethods.sorted()
    }

    /// Longest a canvas verb may take (page load + Mermaid render + export).
    nonisolated static let v2BlueprintCanvasTimeoutSeconds: TimeInterval = 45

    /// Worker-lane entry: runs the body as one main-actor task and waits for
    /// it with the standard bounded semaphore, like `v2AsyncResultCall`.
    nonisolated func v2BlueprintCanvasCommandOnSocketWorker(id: Any?, method: String, params: [String: Any]) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ControlCallResult?
        let task = Task { @MainActor in
            result = await self.blueprintCanvasCommand(method: method, params: params)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + Self.v2BlueprintCanvasTimeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "Request timed out after \(Int(Self.v2BlueprintCanvasTimeoutSeconds)) seconds"
            )
        }
        guard let result else {
            return v2Error(id: id, code: "request_error", message: "Request failed before returning a result")
        }
        return Self.v2Encoder.response(id: Self.v2WireId(id), result)
    }

    @MainActor
    private func blueprintCanvasCommand(method: String, params: [String: Any]) async -> ControlCallResult {
        v2RefreshKnownRefs()
        let target: ControlBlueprintTarget
        switch controlBlueprintTarget(routing: v2BlueprintRouting(params)) {
        case .failure(let failure):
            return failure.callResult
        case .success(let resolved):
            target = resolved
        }
        let state = target.panel.blueprint
        do {
            switch method {
            case "blueprint.set":
                return try await blueprintSet(params, target: target)
            case "blueprint.apply_ops":
                return try await blueprintApplyOps(params, target: target)
            case "blueprint.render_mermaid":
                return try await blueprintRenderMermaid(params, target: target)
            case "blueprint.export":
                return try await blueprintExport(params, target: target)
            case "blueprint.send_to_terminal":
                return try await blueprintSendToTerminal(params, target: target)
            default:
                return .err(code: "invalid_dispatch", message: "Unhandled blueprint method \(method)", data: nil)
            }
        } catch {
            return Self.blueprintErrorResult(error, state: state)
        }
    }

    // MARK: - Verbs

    @MainActor
    private func blueprintSet(_ params: [String: Any], target: ControlBlueprintTarget) async throws -> ControlCallResult {
        guard let sceneJSON = Self.blueprintSceneJSON(params["scene"]) else {
            return .err(code: "invalid_params", message: "scene must be an Excalidraw scene object or its JSON text", data: nil)
        }
        _ = try await target.panel.blueprint.setScene(
            sceneJSON,
            baseRevision: v2Int(params, "base_revision"),
            author: Self.blueprintAuthor(params),
            autoOpen: v2Bool(params, "auto_open")
        )
        return .ok(.object(blueprintMutationPayload(target)))
    }

    @MainActor
    private func blueprintApplyOps(_ params: [String: Any], target: ControlBlueprintTarget) async throws -> ControlCallResult {
        guard let ops = params["ops"] as? [[String: Any]] else {
            return .err(code: "invalid_params", message: "ops must be an array of {op, element|id} objects", data: nil)
        }
        let outcome = try await target.panel.blueprint.applyOps(
            ops,
            baseRevision: v2Int(params, "base_revision"),
            author: Self.blueprintAuthor(params),
            autoOpen: v2Bool(params, "auto_open")
        )
        var payload = blueprintMutationPayload(target)
        payload["applied"] = .int(Int64(outcome.applied))
        return .ok(.object(payload))
    }

    @MainActor
    private func blueprintRenderMermaid(_ params: [String: Any], target: ControlBlueprintTarget) async throws -> ControlCallResult {
        guard let source = v2RawString(params, "mermaid"),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "mermaid must be a non-empty Mermaid source", data: nil)
        }
        let modeRaw = (v2String(params, "mode") ?? "replace").lowercased()
        guard let mode = TerminalBlueprintState.MermaidMode(rawValue: modeRaw) else {
            return .err(code: "invalid_params", message: "mode must be replace|append", data: nil)
        }
        let outcome = try await target.panel.blueprint.renderMermaid(
            source,
            mode: mode,
            baseRevision: v2Int(params, "base_revision"),
            author: Self.blueprintAuthor(params),
            autoOpen: v2Bool(params, "auto_open")
        )
        var payload = blueprintMutationPayload(target)
        payload["warnings"] = .array(outcome.outcome.warnings.map { .string($0) })
        payload["mode"] = .string(mode.rawValue)
        return .ok(.object(payload))
    }

    @MainActor
    private func blueprintExport(_ params: [String: Any], target: ControlBlueprintTarget) async throws -> ControlCallResult {
        let format = (v2String(params, "format") ?? "png").lowercased()
        let state = target.panel.blueprint
        let outputPath: String?
        if let rawPath = v2String(params, "path") {
            let expanded = (rawPath as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                return .err(code: "invalid_params", message: "path must be absolute", data: .object(["path": .string(rawPath)]))
            }
            outputPath = expanded
        } else {
            outputPath = nil
        }
        state.loadDocumentIfNeeded()
        await state.waitForPendingWork()

        switch format {
        case "png", "svg":
            let scale = min(4, max(0.5, v2Double(params, "scale") ?? 2))
            try await state.ensureCanvasReady()
            let export = try await state.requestExport(
                png: format == "png",
                svg: format == "svg",
                mermaid: false,
                scale: scale,
                dark: v2Bool(params, "dark") ?? false
            )
            let data: Data
            if format == "png" {
                guard let png = export.pngData else {
                    return .err(code: "render_failed", message: "The canvas returned no PNG", data: nil)
                }
                data = png
            } else {
                guard let svg = export.svg?.data(using: .utf8) else {
                    return .err(code: "render_failed", message: "The canvas returned no SVG", data: nil)
                }
                data = svg
            }
            let url = try blueprintWriteExport(data, format: format, outputPath: outputPath, target: target)
            var payload: [String: JSONValue] = [
                "format": .string(format),
                "path": .string(url.path),
                "bytes": .int(Int64(data.count)),
                "width": .double(export.width),
                "height": .double(export.height),
                "revision": .int(Int64(state.revision)),
                "surface_id": .string(target.panel.id.uuidString),
            ]
            if v2Bool(params, "inline") == true, data.count <= Self.blueprintInlineExportLimit {
                payload["base64"] = .string(data.base64EncodedString())
            }
            return .ok(.object(payload))
        case "json", "mermaid", "summary":
            let content: String
            switch format {
            case "json":
                content = state.sceneJSON ?? TerminalBlueprintState.emptySceneJSON
            case "mermaid":
                guard let mermaid = state.mermaidSource, !mermaid.isEmpty else {
                    return .err(code: "not_found", message: "No Mermaid source is known for this canvas", data: nil)
                }
                content = mermaid
            default:
                content = state.summaryText
            }
            var payload: [String: JSONValue] = [
                "format": .string(format),
                "revision": .int(Int64(state.revision)),
                "surface_id": .string(target.panel.id.uuidString),
            ]
            if let outputPath {
                let url = URL(fileURLWithPath: outputPath)
                try Data(content.utf8).write(to: url, options: .atomic)
                payload["path"] = .string(url.path)
                payload["bytes"] = .int(Int64(content.utf8.count))
            } else {
                payload["content"] = .string(content)
            }
            return .ok(.object(payload))
        default:
            return .err(code: "invalid_params", message: "format must be png|svg|json|mermaid|summary", data: nil)
        }
    }

    @MainActor
    private func blueprintSendToTerminal(_ params: [String: Any], target: ControlBlueprintTarget) async throws -> ControlCallResult {
        let formats = Set((v2StringArray(params, "formats") ?? ["png", "mermaid"]).map { $0.lowercased() })
        let unknown = formats.subtracting(["png", "mermaid", "summary", "json"])
        guard unknown.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "formats may contain png, mermaid, summary, json",
                data: .object(["unknown": .array(unknown.sorted().map { .string($0) })])
            )
        }
        let options = TerminalBlueprintSendOptions(
            includeMermaid: formats.contains("mermaid"),
            includePNG: formats.contains("png"),
            includeSummary: formats.contains("summary"),
            includeJSON: formats.contains("json"),
            promptPrefix: v2RawString(params, "prompt_prefix"),
            submit: v2Bool(params, "submit") ?? false
        )
        let result = try await target.panel.sendBlueprintToTerminal(options: options)
        return .ok(.object([
            "surface_id": .string(target.panel.id.uuidString),
            "workspace_id": .string(target.workspace.id.uuidString),
            "revision": .int(Int64(result.revision)),
            "png_path": result.pngPath.map { .string($0) } ?? .null,
            "text_length": .int(Int64(result.textLength)),
            "formats": .array(result.formats.map { .string($0) }),
        ]))
    }

    // MARK: - Helpers

    nonisolated static let blueprintInlineExportLimit = 2 * 1024 * 1024

    @MainActor
    private func blueprintMutationPayload(_ target: ControlBlueprintTarget) -> [String: JSONValue] {
        let state = target.panel.blueprint
        return [
            "workspace_id": .string(target.workspace.id.uuidString),
            "surface_id": .string(target.panel.id.uuidString),
            "revision": .int(Int64(state.revision)),
            "element_count": .int(Int64(state.elementCount)),
            "updated_by": .string(state.updatedBy.rawValue),
            "visible": .bool(state.isOpen),
            "collapsed": .bool(state.layout.isCollapsed),
        ]
    }

    @MainActor
    private func blueprintWriteExport(
        _ data: Data,
        format: String,
        outputPath: String?,
        target: ControlBlueprintTarget
    ) throws -> URL {
        if let outputPath {
            let url = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return url
        }
        guard let store = target.panel.blueprintStore else {
            throw TerminalBlueprintError.exportFailed("No export location; pass path")
        }
        // The store is an actor; the write is small and this call site is
        // already async-hopped, so a blocking bridge would be wrong. Use the
        // synchronous URL form and write directly.
        let url = store.exportURL(surfaceID: target.panel.blueprint.surfaceID, fileExtension: format)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Accepts the scene as an object or as its JSON text.
    nonisolated static func blueprintSceneJSON(_ raw: Any?) -> String? {
        if let text = raw as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        if let object = raw as? [String: Any], JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    nonisolated static func blueprintAuthor(_ params: [String: Any]) -> TerminalBlueprintDocument.Author {
        switch (params["source"] as? String)?.lowercased() {
        case "user": return .user
        default: return .agent
        }
    }

    @MainActor
    static func blueprintErrorResult(_ error: any Error, state: TerminalBlueprintState) -> ControlCallResult {
        guard let blueprintError = error as? TerminalBlueprintError else {
            return .err(code: "internal_error", message: error.localizedDescription, data: nil)
        }
        switch blueprintError {
        case .conflict(let revision, let updatedBy):
            return .err(
                code: "conflict",
                message: "The canvas changed since your base revision (now \(revision), by \(updatedBy.rawValue)); read it again and retry",
                data: .object([
                    "revision": .int(Int64(revision)),
                    "updated_by": .string(updatedBy.rawValue),
                    "summary": .string(state.summaryText),
                ])
            )
        case .canvasNotReady, .webViewUnavailable:
            return .err(code: "unavailable", message: "The blueprint canvas did not become ready", data: nil)
        case .exportTimedOut:
            return .err(code: "timeout", message: "The canvas did not answer the export in time", data: nil)
        case .exportFailed(let message), .renderFailed(let message):
            return .err(code: "render_failed", message: message, data: nil)
        case .invalidScene(let message):
            return .err(code: "invalid_params", message: "scene: \(message)", data: nil)
        case .invalidMermaid(let message):
            return .err(code: "invalid_params", message: "mermaid: \(message)", data: nil)
        case .invalidOps(let message):
            return .err(code: "invalid_params", message: "ops: \(message)", data: nil)
        }
    }
}
