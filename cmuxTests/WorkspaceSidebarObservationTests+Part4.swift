import Combine
import CmuxCore
import CMUXAgentLaunch
import Darwin
import Foundation
import Observation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension WorkspaceSidebarObservationTests {
    @Test(.timeLimit(.minutes(1)))
    func agentProcessExitClearsRunningLifecycleWithoutWaitingForPIDPoll() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let pid = process.processIdentifier
        workspace.recordAgentPID(
            key: "codex.process-exit",
            pid: pid,
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        let changes = workspace.sidebarAgentRuntimeObservation.changes()

        process.terminate()

        let cleared = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in changes {
                    let isCleared = await MainActor.run {
                        let lifecycle = workspace.agentLifecycleStatesByPanelId[panelId]?["codex"]
                        return workspace.agentPIDs["codex.process-exit"] == nil
                            && lifecycle == nil
                            && workspace.statusEntries["codex"] == nil
                    }
                    if isCleared {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task<Never, Never>.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(
            cleared,
            "A generation-bound process exit watcher must clear a killed agent immediately instead of leaving Running until the 30-second sweep."
        )
        #expect(workspace.statusEntries["codex"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateExactProcessExitObservationPreservesOriginalWatcher() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let generation = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        let monitor = AgentProcessExitMonitor()
        let (events, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var iterator = events.makeAsyncIterator()
        monitor.observe(key: "codex.duplicate", generation: generation) { _, _ in
            continuation.yield("original")
            continuation.finish()
        }
        monitor.observe(key: "codex.duplicate", generation: generation) { _, _ in
            continuation.yield("replacement")
            continuation.finish()
        }

        process.terminate()

        #expect(
            await iterator.next() == "original",
            "Re-registering an identical process generation must retain its existing exit watcher."
        )
    }

    @Test func unknownProcessLivenessKeepsExitObservation() throws {
        let generation = AgentPIDProcessIdentity(
            pid: pid_t(getpid()),
            startSeconds: 0,
            startMicroseconds: 0
        )
        let monitor = AgentProcessExitMonitor(
            livenessProbe: { _ in .unknown }
        )
        var didRetire = false
        monitor.observe(key: "unknown-liveness", generation: generation) { _, _ in
            didRetire = true
        }

        #expect(
            !didRetire,
            "An unreadable process generation is not proof of exit and must keep its exact watcher until definitive evidence arrives."
        )
        monitor.cancel(key: "unknown-liveness")
    }

    @Test func manuallyClearedAgentPIDCanReRegisterSameLiveGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let generation = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        let key = "codex.manual-unregister"
        #expect(
            workspace.recordAgentPIDResult(
                key: key,
                pid: generation.pid,
                panelId: panelId,
                processIdentity: generation,
                refreshPorts: false,
                observeProcessExit: false
            ).accepted
        )
        #expect(
            workspace.clearAgentPID(
                key: key,
                panelId: panelId,
                clearStatus: true,
                refreshPorts: false
            )
        )

        #expect(
            workspace.recordAgentPIDResult(
                key: key,
                pid: generation.pid,
                panelId: panelId,
                processIdentity: generation,
                refreshPorts: false,
                observeProcessExit: false
            ).accepted,
            "Manual unregister is not process-exit evidence; the same live generation must be admissible again."
        )
    }

    @Test func processExitTombstoneRejectsDelayedLifecycleHook() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        workspace.recordAgentPID(
            key: "codex.delayed-hook",
            pid: process.processIdentifier,
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        process.terminate()
        process.waitUntilExit()
        #expect(workspace.clearStaleAgentPIDs(panelId: panelId, refreshPorts: false))

        // Simulate a queued Stop that was delivered after the process death.
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)

        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil,
            "A delayed hook from a dead PID generation must not resurrect lifecycle state."
        )
    }

    @Test func controlSidebarRejectsAcceptedPIDGenerationThatExitedBeforeDelivery() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let acceptedIdentity = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        process.waitUntilExit()
        let deadPID = process.processIdentifier
        let probeResult = kill(deadPID, 0)
        let probeErrno = errno
        try #require(probeResult != 0)
        try #require(probeErrno == ESRCH)
        let owner = ControlSidebarPanelOwner.workspace(workspace)

        #expect(
            !owner.recordAgentPID(
                key: "codex.dead-before-delivery",
                pid: deadPID,
                panelId: panelId,
                acceptedProcessIdentity: acceptedIdentity
            ).accepted
        )
        owner.setAgentLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running
        )

        #expect(workspace.agentPIDs["codex.dead-before-delivery"] == nil)
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil
        )
    }

    @Test func deadPIDCannotPublishControlSocketStatus() throws {
        let previousManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPID = process.processIdentifier
        let probeResult = kill(deadPID, 0)
        let probeErrno = errno
        try #require(probeResult != 0)
        try #require(probeErrno == ESRCH)

        let response = TerminalController.shared.handleSocketLine(
            "set_status codex Running --icon=bolt.fill --pid=\(deadPID) --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        #expect(response == "OK")
        TerminalMutationBus.shared.drainForTesting()

        #expect(workspace.statusEntries["codex"] == nil)
        #expect(workspace.agentPIDs["codex"] == nil)
    }

    @Test func clearAgentLifecycleWithNilPanelClearsKeySetOnSpecificPanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 1
        )

        // The workspace-scoped `cmux workspace loading off` path clears with a
        // nil panel id; it must remove the key even though `on` targeted a
        // specific panel (the cross-surface off bug).
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 0
        )
    }

    @Test func runningLifecycleQueryIsScopedToOneLoaderKey() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        #expect(workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(!workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.hasRunningAgentLifecycle(key: "codex"))
        #expect(
            SidebarAgentActivitySummary.activeCodingAgentCount(
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ) == 1
        )
    }

    @Test func clearAgentLifecycleStatesPreservesManualLoadersOnLivePanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        // Agent lifecycle resets clear agent keys but must not drop the
        // workspace-scoped manual loader with them.
        workspace.clearAgentLifecycleStates(panelId: panelId)

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["manual"] == .running)
    }

    @Test func activeCodingAgentCountOnlyCountsRunningAgents() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()

        let count = SidebarAgentActivitySummary.activeCodingAgentCount(
            statesByPanelId: [
                firstPanelId: [
                    "codex": .running,
                    "claude_code": .idle,
                    "gemini": .needsInput,
                ],
                secondPanelId: [
                    "opencode": .running,
                    "kiro": .unknown,
                ],
            ]
        )

        #expect(count == 2)
    }

    @Test func visibleActiveCodingAgentCountReturnsZeroWhenSettingIsDisabled() {
        let panelId = UUID()
        let statesByPanelId = [
            panelId: [
                "codex": AgentHibernationLifecycleState.running,
                "claude_code": AgentHibernationLifecycleState.running,
            ],
        ]

        #expect(
            SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: false,
                statesByPanelId: statesByPanelId
            ) == 0
        )
        #expect(
            SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: true,
                statesByPanelId: statesByPanelId
            ) == 2
        )
    }
}
