import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("Codex writer recovery")
struct CodexWriterRecoveryTests {
    @Test("identifies an orphaned app-server holder without treating a live watcher as orphaned")
    func identifiesOrphanedAppServerHolder() {
        let orphan = CodexWriterProcessEvidence(
            pid: 59152,
            parentPID: 1,
            command: "codex app-server --listen ws://127.0.0.1:59152"
        )
        let live = CodexWriterProcessEvidence(
            pid: 59111,
            parentPID: 1234,
            command: "codex app-server --listen ws://127.0.0.1:59111"
        )

        #expect(
            CodexWriterRecoveryAssessment(
                holder: orphan,
                watchedAppServerPorts: []
            ).classification == .orphanedAppServer
        )
        #expect(
            CodexWriterRecoveryAssessment(
                holder: live,
                watchedAppServerPorts: [59111]
            ).classification == .ownedAppServer
        )
    }
}
