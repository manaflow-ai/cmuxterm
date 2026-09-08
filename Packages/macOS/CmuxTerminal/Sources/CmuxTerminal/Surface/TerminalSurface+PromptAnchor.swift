import Foundation
import GhosttyKit
public import CmuxTerminalCore

extension TerminalSurface {
    /// Reads the current terminal write position without changing the viewport.
    @MainActor
    public func stickyPromptAnchor() -> TerminalPromptAnchor? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "stickyPromptAnchor") else {
            return nil
        }
        var before = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &before) else { return nil }
        let captured = ghostty_surface_render_grid_json_v2(
            surface, nil, 0, 0, 0, false, true
        )
        defer { ghostty_string_free(captured) }
        guard let pointer = captured.ptr, captured.len > 0 else { return nil }
        var after = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &after),
              before.row_space_revision == after.row_space_revision else { return nil }
        let data = Data(bytes: pointer, count: Int(captured.len))
        return TerminalPromptWriteSnapshot.decodeAnchor(
            from: data,
            rowSpaceRevision: before.row_space_revision
        )
    }
}
