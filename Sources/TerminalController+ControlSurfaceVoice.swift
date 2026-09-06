import AppKit
import CmuxControlSocket
import Foundation

/// `surface.scroll` and `surface.focus_input` seam bodies. Added for the voice
/// agent (scrolling the CLI and putting the cursor back in the terminal are
/// spoken commands), but generic socket verbs like their siblings.
extension TerminalController {
    /// Ghostty binding actions behind `surface.scroll`.
    nonisolated static func scrollBindingAction(for direction: ControlSurfaceScrollDirection) -> String {
        switch direction {
        case .up: return "scroll_page_up"
        case .down: return "scroll_page_down"
        case .top: return "scroll_to_top"
        case .bottom: return "scroll_to_bottom"
        }
    }

    func controlSurfaceScroll(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        direction: ControlSurfaceScrollDirection,
        pages: Int
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let action = Self.scrollBindingAction(for: direction)
        let repeats = direction == .up || direction == .down ? max(1, pages) : 1

        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .surfaceNotFoundForID
            }
            guard let surfaceId = target.surfaceID else {
                return .noFocusedSurface
            }
            guard target.terminalPanel != nil else {
                return .surfaceNotTerminal(surfaceId)
            }
            guard let terminalTarget = dock.controlSocketTerminalTarget(for: surfaceId) else {
                return .surfaceUnavailable(surfaceId)
            }
            for _ in 0..<repeats {
                guard terminalTarget.performBindingAction(action) else {
                    return .surfaceUnavailable(surfaceId)
                }
            }
            terminalTarget.forceRefresh(reason: "terminalController.v2SurfaceScroll.windowDock")
            return .sent(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                surfaceID: surfaceId,
                queued: false
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let requestedSurfaceID: UUID
        if hasSurfaceIDParam {
            guard let surfaceID else { return .surfaceNotFoundForID }
            requestedSurfaceID = surfaceID
        } else {
            guard let focused = ws.controlDefaultTerminalTarget(paneID: routing.paneID)?.surfaceID else {
                return .noFocusedSurface
            }
            requestedSurfaceID = focused
        }
        guard ws.controlTerminalTarget(for: requestedSurfaceID) != nil else {
            return .surfaceNotTerminal(requestedSurfaceID)
        }
        guard let target = ws.controlSocketTerminalTarget(for: requestedSurfaceID) else {
            return .surfaceUnavailable(requestedSurfaceID)
        }
        for _ in 0..<repeats {
            guard target.performBindingAction(action) else {
                return .surfaceUnavailable(target.surfaceID)
            }
        }
        target.forceRefresh(reason: "terminalController.v2SurfaceScroll")
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: target.surfaceID,
            queued: false
        )
    }

    func controlSurfaceFocusInput(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> (resolution: ControlSurfaceFocusResolution, inputFocused: Bool) {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return (.tabManagerUnavailable, false)
        }
        let targetID: UUID
        if let surfaceID {
            targetID = surfaceID
        } else {
            guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
                return (.workspaceNotFound, false)
            }
            guard let focused = ws.controlDefaultTerminalTarget(paneID: routing.paneID)?.surfaceID
                ?? ws.focusedPanelId else {
                return (.surfaceNotFound(UUID()), false)
            }
            targetID = focused
        }
        let resolution = controlSurfaceFocus(routing: routing, surfaceID: targetID)
        guard case .focused = resolution else {
            return (resolution, false)
        }
        // Hand keyboard focus to the terminal through the window's focus
        // coordinator, the same path the Toggle Right Sidebar Focus shortcut
        // uses to return to the main pane.
        let preferredWindow = v2ResolveWindowId(tabManager: tabManager)
            .flatMap { AppDelegate.shared?.mainWindow(for: $0) }
        let context = AppDelegate.shared?.preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)
            ?? AppDelegate.shared?.mainWindowContext(for: tabManager)
        let inputFocused = context?.keyboardFocusCoordinator.focusTerminal() ?? false
        return (resolution, inputFocused)
    }
}
