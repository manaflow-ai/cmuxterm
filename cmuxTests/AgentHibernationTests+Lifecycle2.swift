import Darwin
import Foundation
import Testing
import Bonsplit
import CmuxCore
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationTests {
    @MainActor
    @Test
    func testClearingAgentPIDByPanelClearsLifecycleWithoutOwnedPID() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .idle)

        expectTrue(workspace.clearAgentPID(key: "codex.missing", panelId: panelId, clearStatus: true))

        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .unknown)
    }

    @MainActor
    @Test
    func testClearingMissingSupersededPIDPreservesReplacementLifecycle() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.recordAgentPID(
            key: "omp.current",
            pid: 12345,
            panelId: panelId,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(key: "omp", panelId: panelId, lifecycle: .running)

        expectFalse(
            workspace.clearAgentPID(
                key: "omp.superseded",
                panelId: panelId,
                clearStatus: true,
                requireOwnedKey: true,
                refreshPorts: false
            )
        )
        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .running)
        expectEqual(workspace.agentPIDs["omp.current"], 12345)
    }

    @MainActor
    @Test
    func testDisagreeingAgentKeysResolveUnknownInsteadOfFixedEnumPrecedence() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "amp", panelId: panelId, lifecycle: .idle)

        expectEqual(
            workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil),
            .unknown
        )
    }

    @Test
    func testLiveGenerationOutranksStaleUnboundLifecycleEvidence() {
        let panelId = UUID()
        let generation = AgentPIDProcessIdentity(
            pid: 42,
            startSeconds: 100,
            startMicroseconds: 200
        )
        var state = AgentLifecycleReconciliationState()

        _ = state.setHookLifecycle(
            key: "amp",
            panelId: panelId,
            lifecycle: .idle,
            isBuiltIn: true
        )
        state.recordProcessGeneration(
            key: "codex",
            panelId: panelId,
            generation: generation,
            isBuiltIn: true
        )
        _ = state.setHookLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running,
            isBuiltIn: true
        )

        expectEqual(
            state.resolvedStatesByPanelId[panelId],
            ["codex": .running]
        )
    }

    @MainActor
    @Test
    func testDetachedRuntimePreservesHiddenDeadGenerationTombstone() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let generation = AgentPIDProcessIdentity(
            pid: 42,
            startSeconds: 100,
            startMicroseconds: 200
        )

        workspace.sidebarAgentRuntimeObservation.recordAgentProcessGeneration(
            key: "codex",
            panelId: panelId,
            generation: generation,
            isBuiltIn: true
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.recordAgentProcessExit(
                key: "codex",
                panelId: panelId,
                generation: generation
            )
        )

        let runtime = try #require(
            workspace.agentRuntimeState(forPanelId: panelId)
        )
        #expect(runtime.agentLifecycleStates.isEmpty)
        #expect(runtime.agentLifecycleReconciliationState.hasEvidence)
    }

    @Test
    func testUnidentifiedExitRejectsHooksUntilExactGenerationArrives() {
        let panelId = UUID()
        let generation = AgentPIDProcessIdentity(
            pid: 43,
            startSeconds: 101,
            startMicroseconds: 201
        )
        var state = AgentLifecycleReconciliationState()

        state.recordUnidentifiedProcessExit(
            key: "codex",
            panelId: panelId,
            isBuiltIn: true
        )
        expectFalse(
            state.setHookLifecycle(
                key: "codex",
                panelId: panelId,
                lifecycle: .running,
                isBuiltIn: true
            )
        )

        state.recordProcessGeneration(
            key: "codex",
            panelId: panelId,
            generation: generation,
            isBuiltIn: true
        )
        expectTrue(
            state.setHookLifecycle(
                key: "codex",
                panelId: panelId,
                lifecycle: .running,
                isBuiltIn: true
            )
        )
        expectEqual(
            state.resolvedStatesByPanelId[panelId],
            ["codex": .running]
        )
    }

    @Test
    func testProcessExitClearsFeedAttentionAndRejectsDelayedApproval() {
        let panelId = UUID()
        let generation = AgentPIDProcessIdentity(
            pid: 44,
            startSeconds: 102,
            startMicroseconds: 202
        )
        var state = AgentLifecycleReconciliationState()

        state.recordProcessGeneration(
            key: "cursor",
            panelId: panelId,
            generation: generation,
            isBuiltIn: true
        )
        let firstToken = state.beginFeedAttention(
            key: "cursor",
            panelId: panelId,
            isBuiltIn: true
        )
        let secondToken = state.beginFeedAttention(
            key: "cursor",
            panelId: panelId,
            isBuiltIn: true
        )
        expectNotNil(firstToken)
        expectNotNil(secondToken)
        expectTrue(
            state.recordProcessExit(
                key: "cursor",
                panelId: panelId,
                generation: generation
            )
        )

        expectNil(state.resolvedStatesByPanelId[panelId]?["cursor"])
        expectNil(
            state.beginFeedAttention(
                key: "cursor",
                panelId: panelId,
                isBuiltIn: true
            )
        )
    }

    @Test
    func testNewerProcessExitRejectsOlderExactHookAndFeedEvidence() {
        let panelId = UUID()
        let olderGeneration = AgentPIDProcessIdentity(
            pid: 47,
            startSeconds: 105,
            startMicroseconds: 100
        )
        let exitedGeneration = AgentPIDProcessIdentity(
            pid: 48,
            startSeconds: 106,
            startMicroseconds: 100
        )
        let replacementGeneration = AgentPIDProcessIdentity(
            pid: 49,
            startSeconds: 107,
            startMicroseconds: 100
        )
        var state = AgentLifecycleReconciliationState()

        state.recordProcessGeneration(
            key: "codex",
            panelId: panelId,
            generation: exitedGeneration,
            isBuiltIn: true
        )
        expectTrue(
            state.recordProcessExit(
                key: "codex",
                panelId: panelId,
                generation: exitedGeneration
            )
        )

        expectFalse(
            state.setHookLifecycle(
                key: "codex",
                panelId: panelId,
                lifecycle: .running,
                isBuiltIn: true,
                processGeneration: olderGeneration
            )
        )
        expectNil(
            state.beginFeedAttention(
                key: "codex",
                panelId: panelId,
                isBuiltIn: true,
                processGeneration: olderGeneration
            )
        )
        expectTrue(
            state.setHookLifecycle(
                key: "codex",
                panelId: panelId,
                lifecycle: .running,
                isBuiltIn: true,
                processGeneration: replacementGeneration
            )
        )
        expectEqual(
            state.resolvedStatesByPanelId[panelId]?["codex"],
            .running
        )
    }

    @Test
    func testFeedAttentionProcessGenerationBridgesPIDRegistrationRace() {
        let panelId = UUID()
        let generation = AgentPIDProcessIdentity(
            pid: 46,
            startSeconds: 105,
            startMicroseconds: 205
        )
        var state = AgentLifecycleReconciliationState()

        let token = state.beginFeedAttention(
            key: "codex",
            panelId: panelId,
            isBuiltIn: true,
            processGeneration: generation
        )

        expectNotNil(token)
        expectEqual(
            state.resolvedStatesByPanelId[panelId]?["codex"],
            .needsInput
        )
        expectTrue(
            state.recordProcessExit(
                key: "codex",
                panelId: panelId,
                generation: generation
            )
        )
        expectNil(state.resolvedStatesByPanelId[panelId]?["codex"])
        expectFalse(
            state.setHookLifecycle(
                key: "codex",
                panelId: panelId,
                lifecycle: .running,
                isBuiltIn: true
            )
        )
    }

    @Test
    func testReplacementProcessGenerationDropsPriorFeedAttention() {
        let panelId = UUID()
        let firstGeneration = AgentPIDProcessIdentity(
            pid: 45,
            startSeconds: 103,
            startMicroseconds: 203
        )
        let replacementGeneration = AgentPIDProcessIdentity(
            pid: 45,
            startSeconds: 104,
            startMicroseconds: 204
        )
        var state = AgentLifecycleReconciliationState()

        state.recordProcessGeneration(
            key: "cursor",
            panelId: panelId,
            generation: firstGeneration,
            isBuiltIn: true
        )
        let staleToken = state.beginFeedAttention(
            key: "cursor",
            panelId: panelId,
            isBuiltIn: true
        )
        expectNotNil(staleToken)

        state.recordProcessGeneration(
            key: "cursor",
            panelId: panelId,
            generation: replacementGeneration,
            isBuiltIn: true
        )

        expectEqual(
            state.resolvedStatesByPanelId[panelId]?["cursor"],
            .unknown
        )
        let replacementToken = state.beginFeedAttention(
            key: "cursor",
            panelId: panelId,
            isBuiltIn: true
        )
        expectNotNil(replacementToken)
        if let staleToken {
            expectFalse(
                state.endFeedAttention(
                    key: "cursor",
                    panelId: panelId,
                    token: staleToken
                )
            )
        } else {
            Issue.record("Expected first-generation Feed attention token")
        }
        expectEqual(
            state.resolvedStatesByPanelId[panelId]?["cursor"],
            .needsInput
        )
        if let replacementToken {
            expectTrue(
                state.endFeedAttention(
                    key: "cursor",
                    panelId: panelId,
                    token: replacementToken
                )
            )
        } else {
            Issue.record("Expected replacement Feed attention token")
        }
    }

    @MainActor
    @Test
    func testDetachedAgentRuntimeExcludesWorkspaceManualLifecycle() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.setAgentLifecycle(key: "manual:loader", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "omp", panelId: panelId, lifecycle: .idle)

        let runtime = try #require(workspace.agentRuntimeState(forPanelId: panelId))
        expectEqual(runtime.agentLifecycleStates["omp"], .idle)
        expectNil(runtime.agentLifecycleStates["manual:loader"])
    }

}
