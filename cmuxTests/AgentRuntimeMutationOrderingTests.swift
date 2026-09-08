import CmuxControlSocket
import CmuxCore
import CmuxSidebar
import CmuxWorkspaces
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Durable idle observations recover the matching agent status", arguments: [
        (RestorableAgentKind.claude, "claude_code"), (.codex, "codex"),
        (.pi, "pi"), (.custom("custom-agent"), "custom-agent")
    ], [false, true])
    func liveIdleObservationUsesAgentStatusKey(
        agent: (RestorableAgentKind, String), stale: Bool
    ) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let (kind, key) = agent
        let runningTime = Date.now.timeIntervalSince1970 - 300
        let idleTime = runningTime + (stale ? -100 : 100)
        #expect(fixture.source.setAgentLifecycle(
            key: key, panelId: fixture.panelId, lifecycle: .running,
            agentEventTime: runningTime
        ))
        _ = fixture.source.upsertSidebarStatusEntry(
            key: key, value: "Running", icon: "bolt.fill", color: "#4C8DFF",
            url: nil, priority: 0, format: .plain, panelId: fixture.panelId,
            pid: nil, agentEventTime: runningTime
        )
        let observation = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(kind: kind, sessionId: "idle-recovery"),
            lifecycle: .idle,
            runtimeStatusEventTime: idleTime,
            updatedAt: runningTime + 200,
            processLiveness: RestorableAgentProcessLiveness.running,
            hasRecordedProcessID: true,
            processIDs: [Int(getpid())], processIdentities: [:],
            agentProcessIDs: [Int(getpid())], agentProcessIdentities: [:],
            hibernationPanelProcessIDs: [], terminationProcessIDs: [],
            terminationProcessIdentities: [:], containsUnrelatedProcess: false
        )

        fixture.source.reconcileLiveIdleAgentStatus(panelId: fixture.panelId, observation: observation)

        let expectedTime = stale ? runningTime : idleTime
        let expectedLifecycle: AgentHibernationLifecycleState = stale ? .running : .idle
        let expectedValue = stale ? "Running" : String(
            localized: "agent.generic.notification.status.idle", defaultValue: "Idle"
        )
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?[key] == expectedLifecycle)
        #expect(fixture.source.statusEntries[key]?.value == expectedValue)
        #expect(fixture.source.statusEntries[key]?.agentEventTime == expectedTime)
        #expect(fixture.source.statusEntries[key]?.agentOwnerPanelID == fixture.panelId)
        #expect(FeedCoordinator.lifecycleStatusKey(forSource: kind.rawValue) == key)

        let delayedRunning = fixture.source.upsertSidebarStatusEntry(
            key: key, value: "Delayed Running", icon: "bolt.fill", color: nil,
            url: nil, priority: 0, format: .plain, panelId: fixture.panelId,
            pid: nil, agentEventTime: expectedTime - 1
        )
        #expect(delayedRunning == .stale)
        #expect(fixture.source.statusEntries[key]?.value == expectedValue)
    }

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
            pid: 43_210
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId
        )

        try movePanel(fixture)
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.destination.statusEntries["claude_code"]?.value == "Running")
        #expect(fixture.destination.agentPIDs["claude_code"] == 43_210)
        #expect(
            fixture.destination.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .running
        )
    }

    @Test("A stale status update cannot rebind PID tracking")
    func staleStatusUpdateDoesNotRecordPID() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 200
        )
        fixture.source.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Idle",
            icon: "pause.circle.fill",
            color: "#8E8E93",
            agentEventTime: 200
        )

        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
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
            pid: 43_210,
            agentEventTime: 100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"]?.value == "Idle")
        #expect(fixture.source.agentPIDs["claude_code"] == nil)
    }

    @Test("Agent status ordering is scoped to the owning pane")
    func agentStatusOrderingIsScopedToOwningPanel() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let paneId = try #require(fixture.source.paneId(forPanelId: fixture.panelId))
        let secondPanelId = try #require(
            fixture.source.newTerminalSurface(inPane: paneId, focus: false)
        ).id
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Running in first pane",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: nil,
            agentEventTime: 1_893_456_200
        )
        bus.drainForTesting()

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Idle in second pane",
            icon: "pause.circle.fill",
            color: "#8E8E93",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: secondPanelId,
            pid: nil,
            agentEventTime: 1_893_456_100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"]?.value == "Idle in second pane")
        #expect(fixture.source.statusEntries["claude_code"]?.agentEventTime == 1_893_456_100)
    }

    @Test("Clearing lifecycle state retains detached-hook ordering authority")
    func clearedLifecycleRetainsStatusOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()

        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 1_893_456_200
        )
        #expect(fixture.source.clearAgentLifecycle(key: "claude_code", panelId: fixture.panelId))

        TerminalController.shared.controlSidebarScheduleStatusUpsert(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            value: "Late stale event",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelID: fixture.panelId,
            pid: 43_210,
            agentEventTime: 1_893_456_100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.source.agentPIDs["claude_code"] == nil)
    }

    @Test("Global lifecycle reset clears retained ordering watermarks")
    func globalLifecycleResetClearsRetainedOrderingWatermarks() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        #expect(fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 1_893_456_200
        ))
        #expect(fixture.source.clearAgentLifecycle(key: "claude_code", panelId: fixture.panelId))
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?["claude_code"] == 1_893_456_200)

        fixture.source.clearAllAgentLifecycleStates()

        #expect(fixture.source.agentLifecycleEventTimesByPanelId.isEmpty)
        #expect(fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 1_893_456_100,
            enforceAgentEventOrdering: true
        ))
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .idle)
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?["claude_code"] == 1_893_456_100)
    }

    @Test("An untimestamped teardown cannot clear timestamped agent runtime")
    func untimestampedAgentPIDClearCannotBypassOrderingWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let pidKey = "claude_code.session"
        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 200
        )
        _ = fixture.source.recordAgentPID(key: pidKey, pid: 43_210, panelId: fixture.panelId)
        _ = fixture.source.upsertSidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: 200
        )

        #expect(!fixture.source.clearAgentPID(
            key: pidKey,
            panelId: fixture.panelId,
            clearStatus: true,
            enforceAgentEventOrdering: true
        ))
        #expect(fixture.source.agentPIDs[pidKey] == 43_210)
        #expect(fixture.source.statusEntries["claude_code"]?.value == "Running")
        #expect(fixture.source.hasRunningAgentLifecycle(key: "claude_code", panelId: fixture.panelId))
    }

    @Test("A stale PID registration cannot bypass a newer runtime watermark")
    func staleAgentPIDRegistrationCannotRebindAfterNewerEvent() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .idle,
            agentEventTime: 200
        )

        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
            target: .workspace(fixture.source.id),
            key: "claude_code.session",
            pid: 43_210,
            panelID: fixture.panelId,
            agentEventTime: 100
        )
        bus.drainForTesting()

        #expect(fixture.source.agentPIDs["claude_code.session"] == nil)
        #expect(fixture.source.agentPIDPanelIdsByKey["claude_code.session"] == nil)
    }

    @Test("An older structured agent cannot replace a newer pane runtime")
    func olderStructuredAgentCannotReplaceNewerPaneRuntime() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let newerKey = "codex.newer-session"
        let olderKey = "claude_code.older-session"

        _ = fixture.source.recordAgentPID(
            key: newerKey,
            pid: 43_210,
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_200,
            enforceAgentEventOrdering: true,
            refreshPorts: false
        )
        _ = fixture.source.recordAgentPID(
            key: olderKey,
            pid: 43_211,
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_100,
            enforceAgentEventOrdering: true,
            refreshPorts: false
        )

        #expect(fixture.source.agentPIDs[newerKey] == 43_210)
        #expect(fixture.source.agentPIDPanelIdsByKey[newerKey] == fixture.panelId)
        #expect(fixture.source.agentPIDs[olderKey] == nil)
        #expect(fixture.source.agentPIDPanelIdsByKey[olderKey] == nil)
    }

    @Test("A displaced structured agent cannot restore pane-owned state")
    func displacedStructuredAgentCannotRestorePaneOwnedState() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        _ = fixture.source.recordAgentPID(
            key: "codex.newer-session",
            pid: 43_210,
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_200,
            enforceAgentEventOrdering: true,
            refreshPorts: false
        )

        let lifecycleAccepted = fixture.source.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panelId,
            lifecycle: .running,
            agentEventTime: 1_893_456_100,
            enforceAgentEventOrdering: true
        )
        let statusDecision = fixture.source.upsertSidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "sparkles",
            color: "#4C8DFF",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: 1_893_456_100
        )
        let notificationAccepted = fixture.source.acceptAgentRuntimeMutation(
            statusKey: "claude_code",
            panelId: fixture.panelId,
            agentEventTime: 1_893_456_100,
            enforceOrdering: true
        )

        #expect(!lifecycleAccepted)
        #expect(statusDecision == .stale)
        #expect(!notificationAccepted)
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == nil)
        #expect(fixture.source.statusEntries["claude_code"] == nil)
        #expect(fixture.source.agentPIDs["codex.newer-session"] == 43_210)
    }

    @Test("A stale lifecycle update cannot bypass a newer status watermark")
    func staleAgentLifecycleCannotBypassNewerStatusWatermark() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        _ = fixture.source.upsertSidebarStatusEntry(
            key: "claude_code",
            value: "Idle",
            icon: "pause.circle.fill",
            color: "#8E8E93",
            url: nil,
            priority: 0,
            format: .plain,
            panelId: fixture.panelId,
            pid: nil,
            agentEventTime: 200
        )

        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(fixture.source.id),
            key: "claude_code",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            panelID: fixture.panelId,
            agentEventTime: 100
        )
        bus.drainForTesting()

        #expect(fixture.source.statusEntries["claude_code"]?.value == "Idle")
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == nil)
    }

    @Test("Arbitrary sidebar keys do not grow durable lifecycle watermarks")
    func arbitrarySidebarKeysDoNotGrowLifecycleWatermarks() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        for index in 0..<64 {
            let key = "custom-status-\(index)"
            let decision = fixture.source.upsertSidebarStatusEntry(
                key: key,
                value: "Value \(index)",
                icon: nil,
                color: nil,
                url: nil,
                priority: 0,
                format: .plain,
                panelId: fixture.panelId,
                pid: nil,
                agentEventTime: 1_893_456_200 + TimeInterval(index)
            )
            #expect(decision == .replace)
        }

        #expect(fixture.source.statusEntries["custom-status-63"]?.agentEventTime == 1_893_456_263)
        #expect(fixture.source.agentLifecycleEventTimesByPanelId[fixture.panelId]?.isEmpty != false)
    }

}
