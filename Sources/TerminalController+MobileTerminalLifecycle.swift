import Foundation

/// The two terminal-lifecycle verbs another Mac's Devices sidebar needs that
/// the mobile plane did not have: close one terminal surface, and rename (or
/// clear the custom name of) one terminal surface. Both resolve the target
/// exactly as `mobile.terminal.input` does, so an attach ticket's terminal
/// scope applies unchanged, and both mutate through the same code paths the
/// local socket verbs use (`surface.close`, `surface.action rename`).
extension TerminalController {
    /// `mobile.terminal.close {workspace_id?, surface_id}`: end the terminal
    /// (its process and pane) on this Mac. Refuses the workspace's last
    /// surface, matching the local socket contract.
    func v2MobileTerminalClose(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let workspace = resolved.workspace
        let surfaceID = resolved.surfaceID
        guard workspace.panels.count > 1 else {
            return .err(code: "invalid_state", message: "Cannot close the last surface", data: [
                "surface_id": surfaceID.uuidString,
            ])
        }
        var closed = false
        v2MainSync {
            closed = workspace.closePanel(surfaceID)
        }
        guard closed else {
            return .err(code: "internal_error", message: "Failed to close surface", data: [
                "surface_id": surfaceID.uuidString,
            ])
        }
        return .ok([
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
            "closed": true,
        ])
    }

    /// `mobile.terminal.rename {workspace_id?, surface_id, title}`: set the
    /// terminal's custom title; an empty title clears it so the shell's own
    /// title shows again.
    func v2MobileTerminalRename(params: [String: Any]) -> V2CallResult {
        guard params["title"] != nil else {
            return .err(code: "invalid_params", message: "Missing title", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let workspace = resolved.workspace
        let surfaceID = resolved.surfaceID
        let title = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        v2MainSync {
            _ = workspace.setPanelCustomTitle(panelId: surfaceID, title: title.isEmpty ? nil : title)
        }
        return .ok([
            "workspace_id": workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
            "title": v2OrNull(title.isEmpty ? nil : title),
        ])
    }
}
