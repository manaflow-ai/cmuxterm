import CmuxControlSocket
import CmuxCore
import CmuxSidebar
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Newer lifecycle events do not veto a guarded current-binding clear", arguments: [false, true])
    func newerLifecycleDoesNotInvalidateCurrentResumeBindingClear(useDock: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let target: ControlSurfaceResumeTarget
        let bindingTime: TimeInterval = 1_893_456_100
        if useDock {
            let dock = try #require(fixture.source.dockSplit)
            let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
            let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
            try #require(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
            target = .dock(tabManager: fixture.manager, dock: dock, surfaceID: fixture.panelId)
        } else {
            target = .workspace(tabManager: fixture.manager, workspace: fixture.source, surfaceID: fixture.panelId)
        }
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex", command: "codex resume current-checkpoint",
            checkpointId: "current-checkpoint", source: "agent-hook", updatedAt: bindingTime
        )
        try #require(target.setBinding(binding, agentEventTime: bindingTime, requiresAgentEventTime: true))
        switch target {
        case .workspace(_, let workspace, let panelID):
            try #require(workspace.setAgentLifecycle(
                key: "codex", panelId: panelID, lifecycle: .running,
                agentEventTime: bindingTime + 100, enforceAgentEventOrdering: true
            ))
        case .dock(_, let dock, let panelID):
            try #require(dock.setAgentLifecycle(
                key: "codex", panelId: panelID, lifecycle: .running,
                agentEventTime: bindingTime + 100, enforceAgentEventOrdering: true
            ))
        }
        // The restore verifier's generation guard still names this binding.
        // Status/lifecycle delivery cannot silently turn that guard stale.
        #expect(target.binding?.updatedAt == bindingTime)
        #expect(target.acceptsBindingMutation(agentEventTime: bindingTime, requiresAgentEventTime: true))
        #expect(target.clearBinding(
            binding, agentSessionEnded: true, agentEventTime: bindingTime, requiresAgentEventTime: true
        ))
        #expect(target.binding == nil)
    }

    @Test("Dock-owned notifications use the pane runtime ordering watermark")
    func dockOwnedNotificationsUsePaneRuntimeOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        defer { bus.discardPendingNotifications() }

        let dock = try #require(fixture.source.dockSplit)
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
        #expect(dock.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 200,
            enforceAgentEventOrdering: true
        ))

        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale Dock notification",
            agentStatusKey: "claude_code",
            agentEventTime: 100,
            coalesces: false
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Current Dock notification",
            agentStatusKey: "claude_code",
            agentEventTime: 300,
            coalesces: false
        )
        bus.drainForTesting()

        #expect(!fixture.store.notifications.contains { $0.body == "Stale Dock notification" })
        #expect(fixture.store.notifications.contains { $0.body == "Current Dock notification" })
        #expect(
            dock.agentRuntimeByPanelId[fixture.panelId]?.agentLifecycleEventTimes["claude_code"] == 300
        )

        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 250
        )
        bus.drainForTesting()
        #expect(fixture.store.notifications.contains { $0.body == "Current Dock notification" })

        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 400
        )
        bus.drainForTesting()
        #expect(!fixture.store.notifications.contains { $0.body == "Current Dock notification" })
    }

    @Test("A no-op Dock resume clear does not advance hook ordering")
    func noOpDockResumeClearDoesNotAdvanceOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let dock = try #require(fixture.source.dockSplit)
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false) == fixture.panelId)
        #expect(dock.surfaceResumeBinding(panelId: fixture.panelId) == nil)

        #expect(!dock.clearSurfaceResumeBinding(
            panelId: fixture.panelId,
            agentSessionEnded: true
        ))
        #expect(dock.surfaceResumeBindingEventTimesByPanelId[fixture.panelId] == nil)

        let eventTime: TimeInterval = 1_893_456_200
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume after-no-op-dock-clear",
            checkpointId: "after-no-op-dock-clear",
            source: "agent-hook",
            updatedAt: eventTime
        )
        #expect(dock.setSurfaceResumeBinding(
            binding,
            panelId: fixture.panelId,
            agentEventTime: eventTime
        ))
        #expect(dock.surfaceResumeBinding(panelId: fixture.panelId)?.checkpointId == "after-no-op-dock-clear")
    }

    @Test("Feed attention overlays do not advance hook ordering watermarks")
    func feedAttentionOverlayDoesNotAdvanceHookOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let hookEventTime: TimeInterval = 1_893_456_200

        #expect(fixture.source.setAgentLifecycle(
            key: "codex",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: hookEventTime
        ))
        #expect(fixture.source.upsertSidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: hookEventTime
        ) == .replace)

        let decision = ControlSidebarPanelOwner.workspace(fixture.source).setStatusEntry(
            SidebarStatusEntry(
                key: "codex",
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            ),
            key: "codex",
            panelId: fixture.panelId
        )
        #expect(decision == .replace)
        #expect(fixture.source.statusEntries["codex"]?.value == "Needs input")
        #expect(fixture.source.statusEntries["codex"]?.agentEventTime == hookEventTime)
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?["codex"] == hookEventTime)

        #expect(fixture.source.setAgentLifecycle(
            key: "codex",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: hookEventTime
        ))
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["codex"] == .idle)
    }

    @Test("Agent notification delivery and clear share event ordering")
    func agentNotificationDeliveryAndClearShareEventOrdering() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Current event",
            agentStatusKey: "claude_code",
            agentEventTime: 200,
            coalesces: false
        )
        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 100
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.map(\.body) == ["Current event"])

        bus.setDrainsSuspendedForTesting(true)
        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 300
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale event",
            agentStatusKey: "claude_code",
            agentEventTime: 250,
            coalesces: false
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.isEmpty)
    }

    @Test("Coalesced agent clears retain the greatest event time and latest notification boundary")
    func coalescedAgentClearsRetainOrderingAndBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
        }

        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 300
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale between coalesced clears",
            agentStatusKey: "claude_code",
            agentEventTime: 250,
            coalesces: false
        )
        bus.enqueueAgentNotificationClear(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId,
            statusKey: "claude_code",
            agentEventTime: 100
        )
        bus.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Current after coalesced clears",
            agentStatusKey: "claude_code",
            agentEventTime: 350,
            coalesces: false
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.store.notifications.map(\.body) == ["Current after coalesced clears"])
    }
}
