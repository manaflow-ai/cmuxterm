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
    @Test func sidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    @Test func agentRuntimeObservationChangesWhenAgentPIDMakesExistingStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Structured agent statuses stay hidden until a live agent runtime owns the status key."
        )

        let generationBeforeRecord = workspace.sidebarAgentRuntimeObservation.changeGeneration
        var workspaceWillChangeCount = 0
        let objectWillChangeCancellable = workspace.objectWillChange.sink {
            workspaceWillChangeCount += 1
        }
        defer { objectWillChangeCancellable.cancel() }

        workspace.recordAgentPID(
            key: "codex.session-b",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Recording the agent PID makes the existing Running status visible."
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > generationBeforeRecord,
            "Agent PID ownership changes must notify the sidebar row runtime observation stream."
        )
        #expect(
            workspaceWillChangeCount == 0,
            "Agent PID ownership is sidebar presentation state and must not broadly invalidate Workspace observers."
        )
    }

    @Test func separateAmpProcessesCannotMoveOrCancelEachOthersPaneOwnership() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let secondPanel = try #require(
            workspace.newTerminalSplit(
                from: firstPanelId,
                orientation: .horizontal
            )
        )
        let firstGeneration = AgentPIDProcessIdentity(
            pid: 1_001,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let firstKey = try #require(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "thread-a",
                processGeneration: firstGeneration
            )
        )
        let siblingThreadKey = try #require(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "thread-b",
                processGeneration: firstGeneration
            )
        )
        let secondKey = try #require(
            AgentLifecycleProcessOwnershipScope.sharedProcess.agentPIDKey(
                statusKey: BuiltInAgentIntegration.amp.statusKey,
                sessionId: "thread-c",
                processGeneration: AgentPIDProcessIdentity(
                    pid: 2_002,
                    startSeconds: 200,
                    startMicroseconds: 20
                )
            )
        )

        #expect(firstKey == siblingThreadKey)
        #expect(firstKey != secondKey)
        workspace.recordAgentPID(
            key: firstKey,
            pid: 1_001,
            panelId: firstPanelId,
            refreshPorts: false
        )
        workspace.recordAgentPID(
            key: secondKey,
            pid: 2_002,
            panelId: secondPanel.id,
            refreshPorts: false
        )

        #expect(workspace.agentPIDPanelIdsByKey[firstKey] == firstPanelId)
        #expect(workspace.agentPIDPanelIdsByKey[secondKey] == secondPanel.id)
        #expect(
            workspace.clearAgentPID(
                key: firstKey,
                panelId: firstPanelId,
                refreshPorts: false
            )
        )
        #expect(workspace.agentPIDPanelIdsByKey[secondKey] == secondPanel.id)
        #expect(workspace.agentPIDs[secondKey] == 2_002)
    }

    @Test
    func reconciledFeedAttentionMakesPreRegisteredStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["cursor"] = SidebarStatusEntry(
            key: "cursor",
            value: FeedCoordinator.needsInputStatusValue,
            icon: "bell.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == "cursor"
            }
        )

        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let token = try #require(
            workspace.beginAgentFeedAttention(
                key: "cursor",
                panelId: panelId,
                processGeneration: generation
            )
        )

        #expect(workspace.agentPIDs.isEmpty)
        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == "cursor"
            },
            "Exact-generation attention evidence must surface Needs Input even when its detached PID registration has not arrived yet."
        )

        #expect(
            workspace.endAgentFeedAttention(
                key: "cursor",
                panelId: panelId,
                token: token
            )
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains {
                $0.key == "cursor"
            }
        )
    }

    @Test
    func relayAttentionRejectsGenerationOlderThanAuthoritativeHook() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_001,
            relayID: "relay-generation-test",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-relay-generation-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let older = AgentPIDProcessIdentity(
            pid: 4_242,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let newer = AgentPIDProcessIdentity(
            pid: 4_141,
            startSeconds: 200,
            startMicroseconds: 20
        )
        #expect(
            workspace.setAgentLifecycle(
                key: "amp",
                panelId: panelId,
                lifecycle: .idle,
                processGeneration: newer
            )
        )

        let sessionId = "relay-generation-\(UUID().uuidString)"
        let observationId = "observation-\(UUID().uuidString)"
        let scopeId = "scope-\(UUID().uuidString)"
        let began = FeedCoordinator.shared.beginObservedAgentAttention(
            source: "amp",
            sessionId: sessionId,
            observationId: observationId,
            scopeId: scopeId,
            workspaceId: workspace.id,
            surfaceId: panelId,
            processGeneration: older
        )
        defer {
            if began {
                _ = FeedCoordinator.shared.endObservedAgentAttention(
                    source: "amp",
                    sessionId: sessionId,
                    observationId: observationId,
                    scopeId: scopeId,
                    processGeneration: older
                )
            }
        }

        #expect(
            !began,
            "A delayed relay approval from an older process generation must not override newer hook state."
        )
        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelId
            )
        )
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["amp"] == .idle)
    }

    @Test
    func newerRelayGenerationRetiresOlderObservedAttention() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_004,
            relayID: "relay-replacement-test",
            relayToken: String(repeating: "r", count: 64),
            localSocketPath: "/tmp/cmux-relay-replacement-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: workspace.id,
                panelId: panelId
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let older = AgentPIDProcessIdentity(
            pid: 4_242,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let newer = AgentPIDProcessIdentity(
            pid: 4_242,
            startSeconds: 200,
            startMicroseconds: 20
        )
        let runningStatus = SidebarStatusEntry(
            key: "amp",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        workspace.statusEntries["amp"] = runningStatus
        #expect(
            FeedCoordinator.shared.beginObservedAgentAttention(
                source: "amp",
                sessionId: "relay-replacement-old",
                observationId: "relay-replacement-observation",
                scopeId: "relay-replacement-scope",
                workspaceId: workspace.id,
                surfaceId: panelId,
                processGeneration: older
            )
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelId
            )
        )

        #expect(
            ControlSidebarPanelOwner.workspace(workspace).setAgentLifecycle(
                key: "amp",
                panelId: panelId,
                lifecycle: .running,
                processGeneration: newer
            )
        )

        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: panelId
            ),
            "An accepted replacement relay generation must retire attention owned by the superseded process."
        )
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelId]?["amp"] == .running
        )
        #expect(
            workspace.statusEntries["amp"] == runningStatus,
            "Concluding native attention must restore the status that was visible before the prompt."
        )
    }

}
