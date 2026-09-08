import Foundation
import CmuxTerminalCore

extension CmuxEventBus {
    func publishWorkspacePromptSubmitted(
        workspaceId: UUID,
        surfaceId: UUID? = nil,
        message: String?,
        preview: String?,
        promptAnchor: TerminalPromptAnchor? = nil,
        source: String = "workspace.prompt_submit"
    ) {
        publish(
            name: "workspace.prompt.submitted",
            category: "workspace",
            source: source,
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId?.uuidString,
            payload: [
                "workspace_id": workspaceId.uuidString,
                "surface_id": surfaceId?.uuidString ?? NSNull(),
                "message": NSNull(),
                "message_preview": preview ?? NSNull(),
                "message_length": message?.count ?? 0,
                "scrollback_row": promptAnchor?.row ?? NSNull(),
                "scrollback_row_space_revision": promptAnchor?.rowSpaceRevision ?? NSNull(),
                "redacted_fields": ["message"]
            ]
        )
    }
}
