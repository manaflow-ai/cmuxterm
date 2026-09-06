internal import Foundation

/// The blueprint domain: the main-actor reads and drawer verbs of the
/// per-terminal diagram canvas (`blueprint.state`, `blueprint.get`,
/// `blueprint.show|hide|collapse|expand`).
extension ControlCommandCoordinator {
    /// The formats `blueprint.get` accepts.
    static let blueprintContentFormats: [String] = ["summary", "json", "mermaid"]

    var blueprintContext: (any ControlBlueprintContext)? {
        context as? any ControlBlueprintContext
    }

    /// Dispatches the blueprint-domain methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    func handleBlueprint(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "blueprint.state":
            return blueprintState(request.params)
        case "blueprint.get":
            return blueprintGet(request.params)
        case "blueprint.show":
            return blueprintVisibility(request.params, action: .show)
        case "blueprint.hide":
            return blueprintVisibility(request.params, action: .hide)
        case "blueprint.collapse":
            return blueprintVisibility(request.params, action: .collapse)
        case "blueprint.expand":
            return blueprintVisibility(request.params, action: .expand)
        default:
            return nil
        }
    }

    func blueprintState(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = blueprintContext?.controlBlueprintState(routing: routingSelectors(params)) ?? .workspaceNotFound
        return blueprintResolve(resolution) { snapshot in
            .ok(.object(blueprintStatePayload(snapshot)))
        }
    }

    func blueprintGet(_ params: [String: JSONValue]) -> ControlCallResult {
        let format = (string(params, "format") ?? "summary").lowercased()
        guard Self.blueprintContentFormats.contains(format) else {
            return .err(
                code: "invalid_params",
                message: "format must be one of \(Self.blueprintContentFormats.joined(separator: "|"))",
                data: .object(["format": .string(format)])
            )
        }
        let resolution = blueprintContext?.controlBlueprintContent(
            routing: routingSelectors(params),
            format: format
        ) ?? .workspaceNotFound
        return blueprintResolve(resolution) { content in
            .ok(.object([
                "workspace_id": .string(content.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, content.workspaceID),
                "surface_id": .string(content.surfaceID.uuidString),
                "surface_ref": ref(.surface, content.surfaceID),
                "revision": .int(Int64(content.revision)),
                "format": .string(content.format),
                "content": orNull(content.content),
            ]))
        }
    }

    func blueprintVisibility(
        _ params: [String: JSONValue],
        action: ControlBlueprintVisibilityAction
    ) -> ControlCallResult {
        let resolution = blueprintContext?.controlBlueprintSetVisibility(
            routing: routingSelectors(params),
            action: action,
            // Socket policy: drawer verbs never move app focus unless asked.
            requestedFocus: bool(params, "focus") ?? false
        ) ?? .workspaceNotFound
        return blueprintResolve(resolution) { outcome in
            var payload = blueprintStatePayload(outcome.state)
            payload["applied"] = .bool(outcome.applied)
            payload["action"] = .string(action.rawValue)
            return .ok(.object(payload))
        }
    }

    // MARK: - Shared

    func blueprintStatePayload(_ snapshot: ControlBlueprintStateSnapshot) -> [String: JSONValue] {
        [
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "surface_id": .string(snapshot.surfaceID.uuidString),
            "surface_ref": ref(.surface, snapshot.surfaceID),
            "visible": .bool(snapshot.isOpen),
            "collapsed": .bool(snapshot.isCollapsed),
            "revision": .int(Int64(snapshot.revision)),
            "element_count": .int(Int64(snapshot.elementCount)),
            "updated_by": .string(snapshot.updatedBy),
            "unseen_agent_update": .bool(snapshot.hasUnseenAgentUpdate),
            "canvas_ready": .bool(snapshot.canvasReady),
            "has_mermaid": .bool(snapshot.hasMermaid),
            "summary": .string(snapshot.summary),
        ]
    }

    /// Maps the shared target failures to wire errors; `body` renders a success.
    func blueprintResolve<Value>(
        _ resolution: ControlBlueprintResolution<Value>,
        _ body: (Value) -> ControlCallResult
    ) -> ControlCallResult {
        switch resolution {
        case .featureDisabled:
            return Self.blueprintDisabledError
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Surface is not a terminal in that workspace",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .noFocusedTerminal:
            return .err(code: "not_found", message: "No focused terminal; pass surface_id", data: nil)
        case .resolved(let value):
            return body(value)
        }
    }

    /// The one error every `blueprint.*` verb returns while the beta is off.
    static let blueprintDisabledError: ControlCallResult = .err(
        code: "unavailable",
        message: "Blueprint is off. Turn it on in Settings › Beta Features › Blueprint.",
        data: .object(["setting": .string("blueprint.beta.enabled")])
    )
}
