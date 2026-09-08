import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationSessionEndIntentTests {
    @MainActor
    @Test
    func preservesOnlyMatchingSessionProcessGeneration() {
        let controller = AgentHibernationController.shared
        let key = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let identity = AgentPIDProcessIdentity(pid: 43219, startSeconds: 17, startMicroseconds: 23)
        controller.armSessionEndPreservation(
            panelKey: key,
            intent: AgentHibernationSessionEndIntent(
                sessionID: "hibernating-session",
                processIdentities: [identity]
            )
        )
        defer { controller.disarmSessionEndPreservation(panelKey: key) }

        #expect(
            controller.shouldPreserveSessionEnd(
                workspaceID: key.workspaceId,
                panelID: key.panelId,
                sessionID: "hibernating-session",
                processIdentity: identity
            )
        )
        #expect(
            !controller.shouldPreserveSessionEnd(
                workspaceID: key.workspaceId,
                panelID: key.panelId,
                sessionID: "different-session",
                processIdentity: identity
            )
        )
        #expect(
            !controller.shouldPreserveSessionEnd(
                workspaceID: key.workspaceId,
                panelID: key.panelId,
                sessionID: "hibernating-session",
                processIdentity: AgentPIDProcessIdentity(pid: 43219, startSeconds: 18, startMicroseconds: 1)
            )
        )
    }
}
