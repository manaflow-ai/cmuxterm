public import Foundation

/// The position-only projection of a screen-anchored Ghostty render snapshot.
public enum TerminalPromptWriteSnapshot {
    /// Decodes the write cursor independently of the user's review viewport.
    ///
    /// The caller validates the opaque row-space identity across capture.
    /// Alternate-screen snapshots have no persistent scrollback attribution.
    public static func decodeAnchor(
        from data: Data,
        rowSpaceRevision: UInt64
    ) -> TerminalPromptAnchor? {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.anchor == "screen", snapshot.activeScreen == "primary",
              snapshot.rows > 0, snapshot.cursor.row < snapshot.rows else { return nil }
        let position = snapshot.historyRows.addingReportingOverflow(snapshot.cursor.row)
        guard !position.overflow, let row = Int(exactly: position.partialValue) else { return nil }
        return TerminalPromptAnchor(row: row, rowSpaceRevision: rowSpaceRevision)
    }

    private struct Cursor: Decodable {
        let row: UInt64
    }

    private struct Snapshot: Decodable {
        let anchor: String
        let activeScreen: String
        let historyRows: UInt64
        let rows: UInt64
        let cursor: Cursor

        enum CodingKeys: String, CodingKey {
            case anchor, rows, cursor
            case activeScreen = "active_screen"
            case historyRows = "history_rows"
        }
    }
}
