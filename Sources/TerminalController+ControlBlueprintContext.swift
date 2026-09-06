import CmuxControlSocket
import Foundation

/// The app-side conformance for the blueprint domain of the control seam:
/// resolves the routed terminal and reads or drives its
/// `TerminalBlueprintState` through the same shared action path the drawer,
/// palette, menu, and shortcut use.
extension TerminalController: ControlBlueprintContext {
    /// A routed terminal and the workspace that owns it.
    struct ControlBlueprintTarget {
        let tabManager: TabManager
        let workspace: Workspace
        let panel: TerminalPanel
    }

    enum ControlBlueprintTargetFailure: Error, Equatable {
        case featureDisabled
        case workspaceNotFound
        case surfaceNotFound(UUID)
        case noFocusedTerminal
    }

    func controlBlueprintState(
        routing: ControlRoutingSelectors
    ) -> ControlBlueprintResolution<ControlBlueprintStateSnapshot> {
        switch controlBlueprintTarget(routing: routing) {
        case .failure(let failure):
            return failure.resolution()
        case .success(let target):
            // Kick the stored document load so a first read reports the real revision soon.
            target.panel.blueprint.loadDocumentIfNeeded()
            return .resolved(controlBlueprintSnapshot(target))
        }
    }

    func controlBlueprintContent(
        routing: ControlRoutingSelectors,
        format: String
    ) -> ControlBlueprintResolution<ControlBlueprintContent> {
        switch controlBlueprintTarget(routing: routing) {
        case .failure(let failure):
            return failure.resolution()
        case .success(let target):
            let state = target.panel.blueprint
            state.loadDocumentIfNeeded()
            let content: String?
            switch format {
            case "json":
                content = state.sceneJSON ?? TerminalBlueprintState.emptySceneJSON
            case "mermaid":
                content = state.mermaidSource
            default:
                content = state.summaryText
            }
            return .resolved(ControlBlueprintContent(
                workspaceID: target.workspace.id,
                surfaceID: target.panel.id,
                revision: state.revision,
                format: format,
                content: content
            ))
        }
    }

    func controlBlueprintSetVisibility(
        routing: ControlRoutingSelectors,
        action: ControlBlueprintVisibilityAction,
        requestedFocus: Bool
    ) -> ControlBlueprintResolution<ControlBlueprintVisibilityOutcome> {
        switch controlBlueprintTarget(routing: routing) {
        case .failure(let failure):
            return failure.resolution()
        case .success(let target):
            let intent: TerminalBlueprintState.Intent
            switch action {
            case .show: intent = .open
            case .hide: intent = .close
            case .collapse: intent = .collapse
            case .expand: intent = .expand
            }
            let applied = target.panel.blueprint.perform(intent)
            if action == .show, v2FocusAllowed(requested: requestedFocus) {
                v2MaybeFocusWindow(for: target.tabManager)
                v2MaybeSelectWorkspace(target.tabManager, workspace: target.workspace)
            }
            return .resolved(ControlBlueprintVisibilityOutcome(
                applied: applied,
                state: controlBlueprintSnapshot(target)
            ))
        }
    }

    // MARK: - Shared resolution

    /// Resolves `blueprint.*` routing to one terminal panel: an explicit
    /// `surface_id` must name a terminal in the routed workspace; without one
    /// the workspace's focused terminal is the target.
    func controlBlueprintTarget(
        routing: ControlRoutingSelectors
    ) -> Result<ControlBlueprintTarget, ControlBlueprintTargetFailure> {
        guard TerminalBlueprintFeature.isEnabled() else { return .failure(.featureDisabled) }
        guard let tabManager = resolveTabManager(routing: routing) else { return .failure(.workspaceNotFound) }
        guard let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .failure(.workspaceNotFound)
        }
        if let surfaceID = routing.surfaceID {
            guard let panel = workspace.panels[surfaceID] as? TerminalPanel else {
                return .failure(.surfaceNotFound(surfaceID))
            }
            return .success(ControlBlueprintTarget(tabManager: tabManager, workspace: workspace, panel: panel))
        }
        guard let focused = workspace.controlDefaultTerminalTarget(paneID: routing.paneID) else {
            return .failure(.noFocusedTerminal)
        }
        return .success(ControlBlueprintTarget(tabManager: tabManager, workspace: workspace, panel: focused.panel))
    }

    func controlBlueprintSnapshot(_ target: ControlBlueprintTarget) -> ControlBlueprintStateSnapshot {
        let state = target.panel.blueprint
        return ControlBlueprintStateSnapshot(
            workspaceID: target.workspace.id,
            surfaceID: target.panel.id,
            isOpen: state.isOpen,
            isCollapsed: state.layout.isCollapsed,
            revision: state.revision,
            elementCount: state.elementCount,
            updatedBy: state.updatedBy.rawValue,
            hasUnseenAgentUpdate: state.hasUnseenAgentUpdate,
            canvasReady: state.isWebViewReady,
            hasMermaid: !(state.mermaidSource ?? "").isEmpty,
            summary: state.summaryText
        )
    }

    /// The routing selectors of a worker-lane request, built like
    /// `surface.read_text` does so both lanes accept the same aliases.
    nonisolated func v2BlueprintRouting(_ params: [String: Any]) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: v2HasNonNullParam(params, "window_id"),
            windowID: v2UUID(params, "window_id"),
            groupID: v2UUID(params, "group_id"),
            workspaceID: v2UUID(params, "workspace_id"),
            surfaceID: v2UUID(params, "surface_id") ?? v2UUID(params, "terminal_id") ?? v2UUID(params, "tab_id"),
            paneID: v2UUID(params, "pane_id")
        )
    }
}

extension TerminalController.ControlBlueprintTargetFailure {
    func resolution<Value>() -> ControlBlueprintResolution<Value> {
        switch self {
        case .featureDisabled: return .featureDisabled
        case .workspaceNotFound: return .workspaceNotFound
        case .surfaceNotFound(let id): return .surfaceNotFound(id)
        case .noFocusedTerminal: return .noFocusedTerminal
        }
    }

    /// The same wire errors the coordinator produces, for the worker lane.
    var callResult: ControlCallResult {
        switch self {
        case .featureDisabled:
            return .err(
                code: "unavailable",
                message: "Blueprint is off. Turn it on in Settings › Beta Features › Blueprint.",
                data: .object(["setting": .string("blueprint.beta.enabled")])
            )
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
        }
    }
}
