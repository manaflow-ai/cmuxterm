import AppKit
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

extension RemoteResumeBindingTests {
    @Test
    func hookResumeBindingClearRejectsStaleEventTimeButManualClearRemainsAuthoritative() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let initialEventTime = Date.now.timeIntervalSince1970 - 300
        let setResult = try v2Result(request: [
            "id": "ordered-resume-set",
            "method": "surface.resume.set",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "command": "codex resume ordered-session",
                "checkpoint_id": "ordered-session",
                "source": "agent-hook",
                "agent_event_time": initialEventTime,
            ],
        ])
        let setBinding = try #require(setResult["resume_binding"] as? [String: Any])
        #expect(setBinding["updated_at"] as? Double == initialEventTime)

        let untimestampedClear = try v2Result(request: [
            "id": "untimestamped-resume-clear",
            "method": "surface.resume.clear",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "checkpoint_id": "ordered-session",
                "source": "agent-hook",
            ],
        ])
        #expect(untimestampedClear["cleared"] as? Bool == false)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID)?.checkpointId == "ordered-session")

        let staleClear = try v2Result(request: [
            "id": "stale-resume-clear",
            "method": "surface.resume.clear",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "checkpoint_id": "ordered-session",
                "source": "agent-hook",
                "agent_event_time": initialEventTime - 100,
            ],
        ])
        #expect(staleClear["cleared"] as? Bool == false)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID)?.checkpointId == "ordered-session")

        let orderedClear = try v2Result(request: [
            "id": "ordered-resume-clear",
            "method": "surface.resume.clear",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "checkpoint_id": "ordered-session",
                "source": "agent-hook",
                "agent_event_time": initialEventTime + 100,
            ],
        ])
        #expect(orderedClear["cleared"] as? Bool == true)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)

        let untimestampedSet = try v2Result(request: [
            "id": "untimestamped-resume-set-after-clear",
            "method": "surface.resume.set",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "command": "codex resume untimestamped-session",
                "checkpoint_id": "untimestamped-session",
                "source": "agent-hook",
            ],
        ])
        #expect(untimestampedSet["resume_binding"] is NSNull)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)

        let staleSet = try v2Result(request: [
            "id": "stale-resume-set-after-clear",
            "method": "surface.resume.set",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "command": "codex resume stale-session",
                "checkpoint_id": "stale-session",
                "source": "agent-hook",
                "agent_event_time": initialEventTime + 50,
            ],
        ])
        #expect(staleSet["resume_binding"] is NSNull)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)

        let invalidClear = try v2Envelope(request: [
            "id": "invalid-resume-clear-time",
            "method": "surface.resume.clear",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "agent_event_time": 0,
            ],
        ])
        #expect(invalidClear["ok"] as? Bool == false)

        for invalidEventTime in [1.0, 1e300, 4_102_444_801.0] {
            let invalidSet = try v2Envelope(request: [
                "id": "invalid-resume-set-time-\(invalidEventTime)",
                "method": "surface.resume.set",
                "params": [
                    "window_id": windowID.uuidString,
                    "surface_id": surfaceID.uuidString,
                    "command": "codex resume poisoned-session",
                    "checkpoint_id": "poisoned-session",
                    "source": "agent-hook",
                    "agent_event_time": invalidEventTime,
                ],
            ])
            #expect(invalidSet["ok"] as? Bool == false)
        }
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)

        _ = try v2Result(request: [
            "id": "manual-resume-set",
            "method": "surface.resume.set",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "command": "codex resume manual-session",
                "checkpoint_id": "manual-session",
                "source": "manual",
            ],
        ])
        let manualClear = try v2Result(request: [
            "id": "manual-resume-clear",
            "method": "surface.resume.clear",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "checkpoint_id": "manual-session",
                "source": "manual",
            ],
        ])
        #expect(manualClear["cleared"] as? Bool == true)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)
    }

    @Test
    func internalResumeBindingClearRejectsDelayedHookSet() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let originalEventTime = Date.now.timeIntervalSince1970 - 60
        _ = try v2Result(request: [
            "id": "internal-clear-initial-set",
            "method": "surface.resume.set",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "command": "codex resume original-session",
                "checkpoint_id": "original-session",
                "source": "agent-hook",
                "agent_event_time": originalEventTime,
            ],
        ])

        #expect(workspace.clearSurfaceResumeBinding(panelId: surfaceID))
        let delayedSet = try v2Result(request: [
            "id": "delayed-hook-set-after-internal-clear",
            "method": "surface.resume.set",
            "params": [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "command": "codex resume delayed-session",
                "checkpoint_id": "delayed-session",
                "source": "agent-hook",
                "agent_event_time": originalEventTime + 1,
            ],
        ])

        #expect(delayedSet["resume_binding"] is NSNull)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)
    }

    @Test
    func noOpResumeClearDoesNotAdvanceOrderingWatermark() throws {
        let workspace = Workspace()
        let surfaceID = try #require(workspace.focusedPanelId)

        #expect(!workspace.clearSurfaceResumeBinding(panelId: surfaceID))
        #expect(workspace.surfaceResumeBindingEventTimesByPanelId[surfaceID] == nil)

        let eventTime: TimeInterval = 1_893_456_200
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume after-no-op-clear",
            checkpointId: "after-no-op-clear",
            source: "agent-hook",
            updatedAt: eventTime
        )
        #expect(workspace.setSurfaceResumeBinding(
            binding,
            panelId: surfaceID,
            agentEventTime: eventTime
        ))
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID)?.checkpointId == "after-no-op-clear")
    }

    @Test
    func rejectedResumeBindingMutationDoesNotAdvanceOrderingWatermark() throws {
        let workspace = Workspace()
        let surfaceID = try #require(workspace.focusedPanelId)
        let initialEventTime: TimeInterval = 1_893_456_100
        let initialBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume claimed-session",
            checkpointId: "claimed-session",
            source: "agent-hook",
            updatedAt: initialEventTime
        )
        #expect(workspace.setSurfaceResumeBinding(
            initialBinding,
            panelId: surfaceID,
            agentEventTime: initialEventTime
        ))
        #expect(workspace.claimSurfaceResumeBinding(
            panelId: surfaceID,
            expectedCheckpointID: "claimed-session",
            expectedSource: "agent-hook",
            expectedUpdatedAt: initialEventTime
        ))

        let before = workspace.surfaceResumeBindingEventTimesByPanelId[surfaceID]
        let rejectedBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume unrelated-session",
            checkpointId: "unrelated-session",
            source: "agent-hook",
            updatedAt: initialEventTime + 100
        )
        #expect(!workspace.surfaceResumeBindingMutationAllowed(
            rejectedBinding,
            panelId: surfaceID
        ))
        #expect(
            workspace.surfaceResumeBindingEventTimesByPanelId[surfaceID] == before,
            "A rejected claimed mutation must not poison the pane's ordering watermark"
        )
    }

    @Test
    func newerResumeClearWinsWhenItInterleavesBetweenSetAcceptanceAndCommit() throws {
        let workspace = Workspace()
        let surfaceID = try #require(workspace.focusedPanelId)
        let initialBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume initial-session",
            checkpointId: "initial-session",
            source: "agent-hook",
            updatedAt: 1_893_456_100
        )
        let delayedBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume delayed-session",
            checkpointId: "delayed-session",
            source: "agent-hook",
            updatedAt: 1_893_456_200
        )

        #expect(workspace.setSurfaceResumeBinding(initialBinding, panelId: surfaceID))
        #expect(workspace.acceptsSurfaceResumeBindingMutation(
            panelId: surfaceID,
            agentEventTime: delayedBinding.updatedAt
        ))

        #expect(workspace.clearSurfaceResumeBinding(
            panelId: surfaceID,
            eventTime: 1_893_456_300
        ))
        #expect(!workspace.setSurfaceResumeBinding(
            delayedBinding,
            panelId: surfaceID,
            agentEventTime: delayedBinding.updatedAt
        ))
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)
    }

    @Test
    func resumeClearOrderingSurvivesSessionSnapshotRelaunch() throws {
        let workspace = Workspace()
        let surfaceID = try #require(workspace.focusedPanelId)
        let originalBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume original-session",
            checkpointId: "original-session",
            source: "agent-hook",
            updatedAt: 1_893_456_100
        )
        let delayedBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume delayed-session",
            checkpointId: "delayed-session",
            source: "agent-hook",
            updatedAt: 1_893_456_200
        )

        #expect(workspace.setSurfaceResumeBinding(
            originalBinding,
            panelId: surfaceID,
            agentEventTime: originalBinding.updatedAt
        ))
        #expect(workspace.clearSurfaceResumeBinding(
            panelId: surfaceID,
            eventTime: 1_893_456_300
        ))

        let encoded = try JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        let persistedSnapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)
        let restoredWorkspace = Workspace()
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(persistedSnapshot)
        let restoredSurfaceID = try #require(restoredIDs[surfaceID])

        #expect(!restoredWorkspace.setSurfaceResumeBinding(
            delayedBinding,
            panelId: restoredSurfaceID,
            agentEventTime: delayedBinding.updatedAt
        ))
        #expect(restoredWorkspace.surfaceResumeBinding(panelId: restoredSurfaceID) == nil)

        let newerBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume newer-session",
            checkpointId: "newer-session",
            source: "agent-hook",
            updatedAt: 1_893_456_400
        )
        #expect(restoredWorkspace.setSurfaceResumeBinding(
            newerBinding,
            panelId: restoredSurfaceID,
            agentEventTime: newerBinding.updatedAt
        ))
        #expect(restoredWorkspace.surfaceResumeBinding(panelId: restoredSurfaceID)?.checkpointId == "newer-session")
    }

}
