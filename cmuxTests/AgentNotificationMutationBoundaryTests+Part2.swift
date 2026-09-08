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
    @Test("Workspace preserves concurrent sessions owned by one process generation")
    func workspacePreservesSharedStructuredAgentGeneration() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }

        #expect(
            !workspace.recordAgentPID(
                key: "amp.thread-a",
                pid: generation.pid,
                panelId: panelID,
                processIdentity: generation,
                refreshPorts: false
            )
        )
        #expect(
            !workspace.recordAgentPID(
                key: "amp.thread-b",
                pid: generation.pid,
                panelId: panelID,
                processIdentity: generation,
                refreshPorts: false
            )
        )
        #expect(
            workspace.agentPIDKeysByPanelId[panelID]
                == ["amp.thread-a", "amp.thread-b"]
        )
        #expect(
            workspace.setAgentLifecycle(
                key: "amp",
                panelId: panelID,
                lifecycle: .running,
                processGeneration: generation
            )
        )

        #expect(
            workspace.clearAgentPID(
                key: "amp.thread-a",
                panelId: panelID,
                clearStatus: true,
                refreshPorts: false
            )
        )
        #expect(workspace.agentPIDs["amp.thread-b"] == generation.pid)
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelID]?["amp"]
                == .running
        )
    }

    @Test("Dock preserves concurrent sessions owned by one process generation")
    func dockPreservesSharedStructuredAgentGeneration() throws {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            dock.newSurface(kind: .terminal, inPane: paneID, focus: false)
        )
        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )

        #expect(
            !dock.recordAgentPID(
                key: "amp.thread-a",
                pid: generation.pid,
                panelId: panelID,
                processIdentity: generation
            )
        )
        #expect(
            !dock.recordAgentPID(
                key: "amp.thread-b",
                pid: generation.pid,
                panelId: panelID,
                processIdentity: generation
            )
        )
        #expect(
            dock.agentRuntimeByPanelId[panelID]?.agentPIDKeys
                == ["amp.thread-a", "amp.thread-b"]
        )
        #expect(
            dock.setAgentLifecycle(
                key: "amp",
                panelId: panelID,
                lifecycle: .running,
                processGeneration: generation
            )
        )

        #expect(
            dock.clearAgentPID(
                key: "amp.thread-a",
                panelId: panelID,
                clearStatus: true
            )
        )
        #expect(
            dock.agentRuntimeByPanelId[panelID]?
                .agentPIDs["amp.thread-b"] == generation.pid
        )
        #expect(
            dock.agentRuntimeByPanelId[panelID]?
                .agentLifecycleStates["amp"] == .running
        )
    }

    @Test("Dock lifecycle mutations keep the attention projection synchronized")
    func dockLifecycleMutationsKeepAttentionProjectionSynchronized() throws {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            dock.newSurface(kind: .terminal, inPane: paneID, focus: false)
        )
        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )

        #expect(
            dock.recordAgentPIDResult(
                key: "amp.attention",
                pid: generation.pid,
                panelId: panelID,
                processIdentity: generation
            ).accepted
        )
        #expect(
            dock.setAgentLifecycle(
                key: "amp",
                panelId: panelID,
                lifecycle: .needsInput,
                processGeneration: generation
            )
        )
        #expect(dock.agentNeedsInputAttention.surfaceIds.contains(panelID))

        #expect(
            dock.setAgentLifecycle(
                key: "amp",
                panelId: panelID,
                lifecycle: .idle,
                processGeneration: generation
            )
        )
        #expect(!dock.agentNeedsInputAttention.surfaceIds.contains(panelID))

        let token = try #require(
            dock.beginAgentFeedAttention(
                key: "amp",
                panelId: panelID,
                processGeneration: generation
            )
        )
        #expect(dock.agentNeedsInputAttention.surfaceIds.contains(panelID))
        #expect(
            dock.endAgentFeedAttention(
                key: "amp",
                panelId: panelID,
                token: token
            )
        )
        #expect(!dock.agentNeedsInputAttention.surfaceIds.contains(panelID))
    }

    @Test("Native attention resolves a Dock-owned panel")
    func nativeAttentionResolvesDockOwnedPanel() throws {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            dock.newSurface(kind: .terminal, inPane: paneID, focus: false)
        )
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: dock.workspaceId,
                panelId: panelID
            )
            dock.closeAllPanels()
        }
        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        #expect(
            dock.recordAgentPIDResult(
                key: "amp.native",
                pid: generation.pid,
                panelId: panelID,
                processIdentity: generation
            ).accepted
        )

        #expect(
            FeedCoordinator.shared.beginObservedAgentAttention(
                source: "amp",
                sessionId: "dock-native-session-\(UUID().uuidString)",
                observationId: "dock-native-observation-\(UUID().uuidString)",
                scopeId: "dock-native-scope-\(UUID().uuidString)",
                workspaceId: dock.workspaceId,
                surfaceId: panelID,
                processGeneration: generation
            )
        )
        #expect(dock.agentNeedsInputAttention.surfaceIds.contains(panelID))
    }

    @Test("Workspace rejects delayed PID registration before replacing runtime")
    func workspaceRejectsDelayedOlderPIDRegistration() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let newerGeneration = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let olderGeneration = AgentPIDProcessIdentity(
            pid: newerGeneration.pid,
            startSeconds: newerGeneration.startSeconds - 1,
            startMicroseconds: newerGeneration.startMicroseconds
        )
        let key = "cursor.delayed-registration"
        defer { workspace.clearAllAgentPIDs(refreshPorts: false) }

        #expect(
            workspace.recordAgentPIDResult(
                key: key,
                pid: newerGeneration.pid,
                panelId: panelID,
                processIdentity: newerGeneration,
                refreshPorts: false
            ).accepted
        )
        #expect(
            workspace.setAgentLifecycle(
                key: "cursor",
                panelId: panelID,
                lifecycle: .running,
                processGeneration: newerGeneration
            )
        )

        let delayedResult = workspace.recordAgentPIDResult(
            key: key,
            pid: olderGeneration.pid,
            panelId: panelID,
            processIdentity: olderGeneration,
            refreshPorts: false
        )

        #expect(!delayedResult.accepted)
        #expect(workspace.agentPIDs[key] == newerGeneration.pid)
        #expect(
            workspace.agentPIDProcessIdentitiesByKey[key]
                == newerGeneration
        )
        #expect(workspace.agentPIDPanelIdsByKey[key] == panelID)
        #expect(
            workspace.agentLifecycleStatesByPanelId[panelID]?["cursor"]
                == .running
        )
    }

    @Test("Dock rejects delayed PID registration before replacing runtime")
    func dockRejectsDelayedOlderPIDRegistration() throws {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            dock.newSurface(kind: .terminal, inPane: paneID, focus: false)
        )
        let newerGeneration = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let olderGeneration = AgentPIDProcessIdentity(
            pid: newerGeneration.pid,
            startSeconds: newerGeneration.startSeconds - 1,
            startMicroseconds: newerGeneration.startMicroseconds
        )
        let key = "cursor.delayed-registration"

        #expect(
            dock.recordAgentPIDResult(
                key: key,
                pid: newerGeneration.pid,
                panelId: panelID,
                processIdentity: newerGeneration
            ).accepted
        )
        #expect(
            dock.setAgentLifecycle(
                key: "cursor",
                panelId: panelID,
                lifecycle: .running,
                processGeneration: newerGeneration
            )
        )

        let delayedResult = dock.recordAgentPIDResult(
            key: key,
            pid: olderGeneration.pid,
            panelId: panelID,
            processIdentity: olderGeneration
        )

        #expect(!delayedResult.accepted)
        #expect(
            dock.agentRuntimeByPanelId[panelID]?.agentPIDs[key]
                == newerGeneration.pid
        )
        #expect(
            dock.agentRuntimeByPanelId[panelID]?
                .agentPIDProcessIdentities[key] == newerGeneration
        )
        #expect(
            dock.agentRuntimeByPanelId[panelID]?
                .agentLifecycleStates["cursor"] == .running
        )
    }

}
