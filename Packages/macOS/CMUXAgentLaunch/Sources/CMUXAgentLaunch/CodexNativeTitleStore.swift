import Foundation
import SQLite3

/// Reads Codex's authoritative native thread title from its state database.
/// Callers can provide a Codex home or database path for alternate profiles
/// and deterministic fixture tests.
public enum CodexNativeTitleStore {
    /// Returns the non-empty title for an active session, or nil when Codex's
    /// database, session row, or title is unavailable.
    public static func title(
        forSessionId sessionId: String,
        codexHome: String? = nil,
        dbPath: String? = nil
    ) -> String? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }
        let databasePath = dbPath ?? databasePath(forCodexHome: codexHome)

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var statement: OpaquePointer?
        let query = "SELECT title FROM threads WHERE id = ?1 AND archived = 0 LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, normalizedSessionId, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let titleBytes = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let title = String(cString: titleBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func databasePath(forCodexHome codexHome: String?) -> String {
        let home = (codexHome ?? "~/.codex") as NSString
        return URL(fileURLWithPath: home.expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path
    }
}
