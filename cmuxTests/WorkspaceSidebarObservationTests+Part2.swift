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
    @Test
    func unresolvedExplicitSurfaceDoesNotRetargetObservedAttention() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_005,
            relayID: "relay-explicit-surface-test",
            relayToken: String(repeating: "s", count: 64),
            localSocketPath: "/tmp/cmux-relay-explicit-surface-test.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh test-remote"
        )
        defer {
            FeedCoordinator.shared.retireAgentAttention(
                workspaceId: workspace.id,
                panelId: focusedPanelId
            )
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let generation = AgentPIDProcessIdentity(
            pid: 5_252,
            startSeconds: 300,
            startMicroseconds: 30
        )
        #expect(
            !FeedCoordinator.shared.beginObservedAgentAttention(
                source: "amp",
                sessionId: "relay-stale-explicit-surface",
                observationId: "relay-stale-explicit-observation",
                scopeId: "relay-stale-explicit-scope",
                workspaceId: workspace.id,
                surfaceId: UUID(),
                processGeneration: generation
            ),
            "A stale explicit surface identity must fail closed instead of targeting the focused panel."
        )
        #expect(
            !workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "amp",
                panelId: focusedPanelId
            )
        )
        #expect(workspace.statusEntries["amp"] == nil)
    }

    @Test
    func cursorBoundaryRejectsDelayedObserverButAllowsFutureObserver() throws {
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
            relayPort: 64_002,
            relayID: "cursor-boundary-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-cursor-boundary-test.sock",
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

        let coordinator = FeedCoordinator.shared
        let sessionId = "cursor-boundary-\(UUID().uuidString)"
        let generation = AgentPIDProcessIdentity(
            pid: 5_151,
            startSeconds: 300,
            startMicroseconds: 30
        )
        #expect(
            coordinator.endObservedAgentAttention(
                source: "cursor",
                sessionId: sessionId,
                observationId: nil,
                scopeId: nil,
                processGeneration: generation,
                boundaryEpoch: 200
            ) == 0
        )

        #expect(
            !coordinator.beginObservedAgentAttention(
                source: "cursor",
                sessionId: sessionId,
                observationId: "delayed-observation",
                scopeId: "delayed-scope",
                workspaceId: workspace.id,
                surfaceId: panelId,
                processGeneration: generation,
                observationEpoch: 100
            ),
            "A native observer that predates the process boundary must not resurrect attention."
        )

        let futureBegan = coordinator.beginObservedAgentAttention(
            source: "cursor",
            sessionId: sessionId,
            observationId: "future-observation",
            scopeId: "future-scope",
            workspaceId: workspace.id,
            surfaceId: panelId,
            processGeneration: generation,
            observationEpoch: 300
        )
        #expect(
            futureBegan,
            "A later approval in the same long-lived process must remain eligible."
        )
        if futureBegan {
            _ = coordinator.endObservedAgentAttention(
                source: "cursor",
                sessionId: sessionId,
                observationId: "future-observation",
                scopeId: "future-scope",
                processGeneration: generation
            )
        }
    }

    @Test
    func relayBlockingAttentionDoesNotUseTheLocalProcessTable() throws {
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
            relayPort: 64_002,
            relayID: "relay-blocking-attention-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-relay-blocking-attention-test.sock",
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

        let event = WorkstreamEvent(
            sessionId: "relay-blocking-attention",
            hookEventName: .permissionRequest,
            source: "codex",
            workspaceId: workspace.id.uuidString,
            surfaceId: panelId.uuidString,
            requestId: "relay-blocking-attention-request",
            ppid: Int(getpid())
        )
        let target = try #require(
            FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: event,
                resolved: (workspace.id, panelId),
                tabManager: tabManager
            )
        )
        defer {
            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
        }

        #expect(
            target.token.processGeneration == nil,
            "A relay PID must not be resolved against the Mac's local process namespace."
        )
    }

    @Test
    func workspaceOnlyBlockingAttentionSurvivesMissingFocusedPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelId = try #require(workspace.focusedPanelId)
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        let source = "workspace-only-attention"
        var target: FeedAttentionTarget?
        defer {
            if let target {
                FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
            }
            dock.closeAllPanels()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let transfer = try #require(
            workspace.detachSurface(panelId: panelId)
        )
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPaneId,
                focus: false
            ) == panelId
        )
        #expect(workspace.panels.isEmpty)
        #expect(workspace.focusedPanelId == nil)

        target = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
            event: WorkstreamEvent(
                sessionId: "workspace-only-attention-session",
                hookEventName: .permissionRequest,
                source: source,
                requestId: "workspace-only-attention-request"
            ),
            resolved: (ownerId: workspace.id, surfaceId: nil),
            tabManager: tabManager
        )
        #expect(
            target != nil,
            "A blocking Feed decision must retain workspace scope when no panel is usable."
        )
        let statusKey = FeedCoordinator.attentionStatusKey(forSource: source)
        #expect(
            workspace.statusEntries[statusKey]?.value
                == FeedCoordinator.needsInputStatusValue
        )

        if let target {
            FeedCoordinator.shared.concludeBlockingDecisionAttention(target)
            self.assertWorkspaceOnlyAttentionWasCleared(
                workspace,
                statusKey: statusKey
            )
        }
    }

    private func assertWorkspaceOnlyAttentionWasCleared(
        _ workspace: Workspace,
        statusKey: String
    ) {
        #expect(
            workspace.statusEntries[statusKey] == nil,
            "Concluding a workspace-scoped Feed decision must clear its badge."
        )
    }

    @Test
    func workspaceAttentionScopesSeparateAfterOnePanelMovesToDock() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let workspacePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let dockPanelId = try #require(
            workspace.newTerminalSurface(inPane: paneId, focus: false)?.id
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let coordinator = FeedCoordinator.shared

        let workspaceTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "workspace-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "workspace-attention-request"
                ),
                resolved: (workspace.id, workspacePanelId),
                tabManager: tabManager
            )
        )
        let dockTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "dock-bound-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "dock-bound-attention-request"
                ),
                resolved: (workspace.id, dockPanelId),
                tabManager: tabManager
            )
        )
        defer {
            coordinator.concludeBlockingDecisionAttention(workspaceTarget)
            coordinator.concludeBlockingDecisionAttention(dockTarget)
            dock.closeAllPanels()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let transfer = try #require(
            workspace.detachSurface(panelId: dockPanelId)
        )
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(
            dock.attachDetachedSurface(
                transfer,
                inPane: dockPaneId,
                focus: false
            ) == dockPanelId
        )
        #expect(
            ControlSidebarPanelOwner.workspace(workspace).statusEntry(
                key: "codex",
                panelId: workspacePanelId
            ) != nil
        )
        #expect(
            ControlSidebarPanelOwner.dock(dock).statusEntry(
                key: "codex",
                panelId: dockPanelId
            ) != nil
        )

        coordinator.concludeBlockingDecisionAttention(workspaceTarget)

        #expect(
            ControlSidebarPanelOwner.workspace(workspace).statusEntry(
                key: "codex",
                panelId: workspacePanelId
            ) == nil,
            "The workspace badge must clear once its last workspace-owned decision ends."
        )
        #expect(
            ControlSidebarPanelOwner.dock(dock).statusEntry(
                key: "codex",
                panelId: dockPanelId
            ) != nil,
            "The moved panel's Dock-scoped decision must remain visible."
        )

        coordinator.concludeBlockingDecisionAttention(dockTarget)
        #expect(
            ControlSidebarPanelOwner.dock(dock).statusEntry(
                key: "codex",
                panelId: dockPanelId
            ) == nil,
            "The Dock badge must clear when its exact moved decision ends."
        )
    }

}
