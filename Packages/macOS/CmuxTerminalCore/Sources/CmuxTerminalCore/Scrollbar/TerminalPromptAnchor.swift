/// A write-cursor row valid only in the captured Ghostty row space.
public struct TerminalPromptAnchor: Sendable, Equatable {
    /// The zero-based row from the beginning of retained history.
    public let row: Int
    /// The opaque identity of the native surface, screen, and row numbering.
    public let rowSpaceRevision: UInt64

    /// Creates a position captured from one terminal-state snapshot.
    public init(row: Int, rowSpaceRevision: UInt64) {
        self.row = row
        self.rowSpaceRevision = rowSpaceRevision
    }
}
