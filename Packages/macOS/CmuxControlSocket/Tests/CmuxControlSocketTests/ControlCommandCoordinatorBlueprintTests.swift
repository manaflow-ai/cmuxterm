import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the blueprint coordinator
/// domain without the app target.
@MainActor
private final class FakeBlueprintControlCommandContext: ControlCommandContext {
    var stateResolution: ControlBlueprintResolution<ControlBlueprintStateSnapshot> = .workspaceNotFound
    var contentResolution: ControlBlueprintResolution<ControlBlueprintContent> = .workspaceNotFound
    var visibilityResolution: ControlBlueprintResolution<ControlBlueprintVisibilityOutcome> = .workspaceNotFound
    var lastRouting: ControlRoutingSelectors?
    var lastFormat: String?
    var lastAction: ControlBlueprintVisibilityAction?
    var lastRequestedFocus: Bool?

    func controlBlueprintState(
        routing: ControlRoutingSelectors
    ) -> ControlBlueprintResolution<ControlBlueprintStateSnapshot> {
        lastRouting = routing
        return stateResolution
    }

    func controlBlueprintContent(
        routing: ControlRoutingSelectors,
        format: String
    ) -> ControlBlueprintResolution<ControlBlueprintContent> {
        lastRouting = routing
        lastFormat = format
        return contentResolution
    }

    func controlBlueprintSetVisibility(
        routing: ControlRoutingSelectors,
        action: ControlBlueprintVisibilityAction,
        requestedFocus: Bool
    ) -> ControlBlueprintResolution<ControlBlueprintVisibilityOutcome> {
        lastRouting = routing
        lastAction = action
        lastRequestedFocus = requestedFocus
        return visibilityResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator blueprint domain")
struct ControlCommandCoordinatorBlueprintTests {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeCoordinator() -> (ControlCommandCoordinator, FakeBlueprintControlCommandContext) {
        let context = FakeBlueprintControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func snapshot(isOpen: Bool = true, isCollapsed: Bool = false) -> ControlBlueprintStateSnapshot {
        ControlBlueprintStateSnapshot(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            isOpen: isOpen,
            isCollapsed: isCollapsed,
            revision: 7,
            elementCount: 3,
            updatedBy: "user",
            hasUnseenAgentUpdate: false,
            canvasReady: true,
            hasMermaid: true,
            summary: "#a rectangle \"API\" (0,0 100x40)"
        )
    }

    @Test func stateRendersTheSnapshotWithRefs() {
        let (coordinator, context) = makeCoordinator()
        context.stateResolution = .resolved(snapshot())

        let result = coordinator.handle(request("blueprint.state", ["surface_id": .string(surfaceID.uuidString)]))

        // First mint of each kind is ordinal 1.
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "visible": .bool(true),
            "collapsed": .bool(false),
            "revision": .int(7),
            "element_count": .int(3),
            "updated_by": .string("user"),
            "unseen_agent_update": .bool(false),
            "canvas_ready": .bool(true),
            "has_mermaid": .bool(true),
            "summary": .string("#a rectangle \"API\" (0,0 100x40)"),
        ])))
        #expect(context.lastRouting?.surfaceID == surfaceID)
    }

    @Test func stateDefaultsToTheCallerSurfaceWhenNoSelectorIsGiven() {
        let (coordinator, context) = makeCoordinator()
        context.stateResolution = .resolved(snapshot())

        _ = coordinator.handle(request("blueprint.state"))

        #expect(context.lastRouting?.surfaceID == nil)
        #expect(context.lastRouting?.workspaceID == nil)
    }

    @Test func featureDisabledMapsToUnavailableWithTheSettingKey() {
        let (coordinator, context) = makeCoordinator()
        context.stateResolution = .featureDisabled

        guard case .err(let code, _, let data) = coordinator.handle(request("blueprint.state")) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "unavailable")
        #expect(data == .object(["setting": .string("blueprint.beta.enabled")]))
    }

    @Test func targetFailuresMapToNotFound() {
        let (coordinator, context) = makeCoordinator()

        context.stateResolution = .workspaceNotFound
        guard case .err(let workspaceCode, _, _) = coordinator.handle(request("blueprint.state")) else {
            Issue.record("expected err")
            return
        }
        #expect(workspaceCode == "not_found")

        context.stateResolution = .surfaceNotFound(surfaceID)
        guard case .err(let surfaceCode, _, let surfaceData) = coordinator.handle(request("blueprint.state")) else {
            Issue.record("expected err")
            return
        }
        #expect(surfaceCode == "not_found")
        #expect(surfaceData == .object(["surface_id": .string(surfaceID.uuidString)]))

        context.stateResolution = .noFocusedTerminal
        guard case .err(let focusedCode, let focusedMessage, _) = coordinator.handle(request("blueprint.state")) else {
            Issue.record("expected err")
            return
        }
        #expect(focusedCode == "not_found")
        #expect(focusedMessage.contains("surface_id"))
    }

    @Test func getDefaultsToSummaryAndPassesTheFormatThrough() {
        let (coordinator, context) = makeCoordinator()
        context.contentResolution = .resolved(ControlBlueprintContent(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            revision: 2,
            format: "summary",
            content: "(empty blueprint)"
        ))

        let result = coordinator.handle(request("blueprint.get"))

        #expect(context.lastFormat == "summary")
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "revision": .int(2),
            "format": .string("summary"),
            "content": .string("(empty blueprint)"),
        ])))
    }

    @Test func getRendersMissingMermaidAsNull() {
        let (coordinator, context) = makeCoordinator()
        context.contentResolution = .resolved(ControlBlueprintContent(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            revision: 2,
            format: "mermaid",
            content: nil
        ))

        guard case .ok(.object(let payload)) = coordinator.handle(request("blueprint.get", ["format": .string("MERMAID")])) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastFormat == "mermaid")
        #expect(payload["content"] == .null)
    }

    @Test func getRejectsUnknownFormatsBeforeTouchingTheSeam() {
        let (coordinator, context) = makeCoordinator()

        guard case .err(let code, _, _) = coordinator.handle(request("blueprint.get", ["format": .string("png")])) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastFormat == nil)
    }

    @Test func visibilityVerbsDefaultToNoFocusAndReportApplied() {
        let (coordinator, context) = makeCoordinator()
        context.visibilityResolution = .resolved(ControlBlueprintVisibilityOutcome(applied: false, state: snapshot(isOpen: false)))

        guard case .ok(.object(let payload)) = coordinator.handle(request("blueprint.collapse")) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastAction == .collapse)
        #expect(context.lastRequestedFocus == false)
        #expect(payload["applied"] == .bool(false))
        #expect(payload["action"] == .string("collapse"))
        #expect(payload["visible"] == .bool(false))
    }

    @Test func showPassesAnExplicitFocusRequest() {
        let (coordinator, context) = makeCoordinator()
        context.visibilityResolution = .resolved(ControlBlueprintVisibilityOutcome(applied: true, state: snapshot()))

        for (method, action) in [
            ("blueprint.show", ControlBlueprintVisibilityAction.show),
            ("blueprint.hide", .hide),
            ("blueprint.expand", .expand),
        ] {
            _ = coordinator.handle(request(method, ["focus": .bool(true)]))
            #expect(context.lastAction == action)
            #expect(context.lastRequestedFocus == true)
        }
    }

    @Test func unknownBlueprintMethodsFallThrough() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handleBlueprint(request("blueprint.render_mermaid")) == nil)
    }
}
