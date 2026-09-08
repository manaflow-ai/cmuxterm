import CmuxControlSocket
import CmuxCore
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Agent runtime mutations follow a pane that moves before queue drain")
    func queuedAgentRuntimeMutationsResolveLivePanelOwner() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        let processIdentity = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let processGeneration = ControlSidebarAgentProcessGeneration(
            pid: processIdentity.pid,
            startSeconds: processIdentity.startSeconds,
            startMicroseconds: processIdentity.startMicroseconds
        )
        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: getpid(),
            processGeneration: processGeneration
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            processGeneration: processGeneration,
            panelID: fixture.panelId
        )

        try movePanel(fixture)
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.destination.statusEntries["claude_code"]?.value == "Running")
        #expect(fixture.destination.agentPIDs["claude_code"] == getpid())
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .running
        )
    }

    @Test("An authorized-workspace clear cancels a confined in-flight relay delivery")
    func authorizedWorkspaceClearCancelsConfinedInFlightRelayDelivery() async throws {
        let fixture = try makeFixture(policyHookCommand: "cat")
        defer { fixture.restore() }

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: fixture.source.id,
            surfaceID: nil,
            paneID: nil
        )
        let result = TerminalController.shared.controlNotificationCreateForTarget(
            routing: routing,
            workspaceID: fixture.source.id,
            surfaceID: fixture.panelId,
            title: "Relay",
            subtitle: "Completed",
            body: "Must be cancelled by its authorized workspace clear"
        )
        guard case .delivered = result else {
            Issue.record("Expected relay-target delivery, got \(result)")
            return
        }

        try movePanel(fixture)
        // A confined request does not follow its surface — its delivery
        // identity stays the authorized workspace — so clearing that
        // workspace tab-wide must cancel it even though the request carries
        // a surfaceId.
        fixture.store.clearNotifications(forTabId: fixture.source.id)

        for _ in 0..<200 { await Task.yield() }
        let recorded = fixture.store.notifications.filter { $0.title == "Relay" }
        #expect(
            recorded.isEmpty,
            "A confined in-flight delivery must be cancelled by clearing its authorized workspace; saw \(recorded.map(\.tabId))"
        )
    }
}
