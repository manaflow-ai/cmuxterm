public import Foundation

/// One terminal's blueprint drawer as the socket reports it (`blueprint.state`
/// and the visibility verbs).
public struct ControlBlueprintStateSnapshot: Sendable, Equatable {
    public let workspaceID: UUID
    /// The terminal surface that owns the drawer.
    public let surfaceID: UUID
    public let isOpen: Bool
    public let isCollapsed: Bool
    /// Bumped by every accepted mutation, whoever authored it.
    public let revision: Int
    public let elementCount: Int
    /// `user`, `agent`, or `restore`.
    public let updatedBy: String
    /// An agent changed the canvas and the user has not looked since.
    public let hasUnseenAgentUpdate: Bool
    /// The canvas page is live (Mermaid rendering and image export work).
    public let canvasReady: Bool
    /// A Mermaid source is remembered for the current scene.
    public let hasMermaid: Bool
    /// The compact, one-line-per-element text summary.
    public let summary: String

    public init(
        workspaceID: UUID,
        surfaceID: UUID,
        isOpen: Bool,
        isCollapsed: Bool,
        revision: Int,
        elementCount: Int,
        updatedBy: String,
        hasUnseenAgentUpdate: Bool,
        canvasReady: Bool,
        hasMermaid: Bool,
        summary: String
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.isOpen = isOpen
        self.isCollapsed = isCollapsed
        self.revision = revision
        self.elementCount = elementCount
        self.updatedBy = updatedBy
        self.hasUnseenAgentUpdate = hasUnseenAgentUpdate
        self.canvasReady = canvasReady
        self.hasMermaid = hasMermaid
        self.summary = summary
    }
}

/// The canvas in one of the `blueprint.get` formats.
public struct ControlBlueprintContent: Sendable, Equatable {
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let revision: Int
    /// `summary`, `json`, or `mermaid`.
    public let format: String
    /// Nil when the format has nothing to give (no Mermaid source is known).
    public let content: String?

    public init(workspaceID: UUID, surfaceID: UUID, revision: Int, format: String, content: String?) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.revision = revision
        self.format = format
        self.content = content
    }
}

/// The drawer verbs that need no canvas round trip.
public enum ControlBlueprintVisibilityAction: String, Sendable, Equatable {
    case show
    case hide
    case collapse
    case expand
}

/// The drawer after a visibility verb; `applied` is false when the verb was a
/// no-op (collapsing a closed drawer), mirroring the in-app action path.
public struct ControlBlueprintVisibilityOutcome: Sendable, Equatable {
    public let applied: Bool
    public let state: ControlBlueprintStateSnapshot

    public init(applied: Bool, state: ControlBlueprintStateSnapshot) {
        self.applied = applied
        self.state = state
    }
}

/// How a `blueprint.*` target resolved. The coordinator maps every failure to
/// one wire error so the app side never builds responses.
public enum ControlBlueprintResolution<Value: Sendable & Equatable>: Sendable, Equatable {
    /// The Blueprint beta toggle is off.
    case featureDisabled
    case workspaceNotFound
    /// The routed surface is not a terminal in that workspace.
    case surfaceNotFound(UUID)
    /// No `surface_id` was given and the workspace has no focused terminal.
    case noFocusedTerminal
    case resolved(Value)
}

/// The blueprint-domain slice of the control-command seam: the synchronous
/// reads and drawer verbs of the per-terminal diagram canvas. The verbs that
/// wait on the canvas page (`set`, `apply_ops`, `render_mermaid`, `export`,
/// `send_to_terminal`) run on the socket worker lane app-side and are not
/// part of this seam.
@MainActor
public protocol ControlBlueprintContext: AnyObject {
    func controlBlueprintState(
        routing: ControlRoutingSelectors
    ) -> ControlBlueprintResolution<ControlBlueprintStateSnapshot>

    func controlBlueprintContent(
        routing: ControlRoutingSelectors,
        format: String
    ) -> ControlBlueprintResolution<ControlBlueprintContent>

    func controlBlueprintSetVisibility(
        routing: ControlRoutingSelectors,
        action: ControlBlueprintVisibilityAction,
        requestedFocus: Bool
    ) -> ControlBlueprintResolution<ControlBlueprintVisibilityOutcome>
}
