import Foundation
import GhosttyKit

/// The absolute scrollback row at which a prompt was submitted.
public struct TerminalPromptAnchor: Sendable, Equatable {
    public let row: Int
    public let rowSpaceRevision: UInt64

    public init(row: Int, rowSpaceRevision: UInt64) {
        self.row = row
        self.rowSpaceRevision = rowSpaceRevision
    }
}

extension TerminalSurface {
    /// Reads the current terminal write position without changing the viewport.
    @MainActor
    public func stickyPromptAnchor() -> TerminalPromptAnchor? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "stickyPromptAnchor") else {
            return nil
        }
        var scrollbar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &scrollbar) else { return nil }
        let bottomRow = scrollbar.offset + max(scrollbar.len, 1) - 1
        return TerminalPromptAnchor(
            row: Int(min(bottomRow, UInt64(Int.max))),
            rowSpaceRevision: scrollbar.row_space_revision
        )
    }
}
