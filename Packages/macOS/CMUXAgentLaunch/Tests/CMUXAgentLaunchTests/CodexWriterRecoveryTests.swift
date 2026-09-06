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

    @Test("parses recovery and resume thread IDs without mistaking remote arguments")
    func parsesThreadIDsAndRemoteProvider() {
        let threadID = "01234567-89ab-cdef-0123-456789abcdef"

        #expect(
            CodexWriterRecovery.resumeSessionID(arguments: ["codex", "resume", threadID]) == threadID
        )
        #expect(
            CodexWriterRecovery.resumeSessionID(arguments: ["recover", threadID, "--yes"]) == threadID
        )
        #expect(
            CodexWriterRecovery.usesRemoteProvider(arguments: ["codex", "resume", threadID, "--remote", "ws://127.0.0.1:1"])
        )
        #expect(
            !CodexWriterRecovery.usesRemoteProvider(arguments: ["codex", "resume", threadID, "--", "--remote"])
        )
    }

    @Test("recognizes the Codex active-writer failure")
    func recognizesWriterConflict() {
        #expect(
            CodexWriterRecovery.isWriterConflict(
                errorText: "thread/resume failed: thread 123 already has an active writer (code -32600)"
            )
        )
        #expect(!CodexWriterRecovery.isWriterConflict(errorText: "thread not found"))
    }
}
