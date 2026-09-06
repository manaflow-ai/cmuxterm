import CMUXAgentLaunch
import Foundation

/// Localized ownership diagnostics shared by Vault and the restore CLI.
struct CodexWriterRestoreMessage {
    let inspection: CodexWriterRestoreInspection

    var title: String {
        if inspection.lock?.state == .active {
            return String(localized: "sessionIndex.codex.activeWriter.title", defaultValue: "Codex session is already open")
        }
        return String(localized: "sessionIndex.codex.writerCheckUnavailable.title", defaultValue: "Codex session could not be checked")
    }

    var text: String {
        if inspection.lock?.state != .active {
            return String(localized: "codex.restore.writerCheckUnavailable", defaultValue: "cmux could not verify the Codex session owner. No new writer was started. Continue in the original terminal, or retry after checking the Codex account configuration.")
        }
        return String(localized: "codex.restore.activeWriter", defaultValue: "This Codex session already has an active writer. Continue in the original terminal, or exit that Codex session normally before retrying. cmux did not remove the lock or start another writer.")
    }
}
