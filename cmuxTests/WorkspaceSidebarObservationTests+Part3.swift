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
    func dockAttentionScopesMergeWhenPanelsMoveIntoOneWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let sourceWorkspace = tabManager.addWorkspace(select: true)
        let destinationWorkspace = tabManager.addWorkspace(select: false)
        let firstPanelId = try #require(sourceWorkspace.focusedPanelId)
        let sourcePaneId = try #require(
            sourceWorkspace.bonsplitController.focusedPaneId
        )
        let secondPanelId = try #require(
            sourceWorkspace.newTerminalSurface(
                inPane: sourcePaneId,
                focus: false
            )?.id
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        let dockPaneId = try #require(dock.bonsplitController.allPaneIds.first)
        for panelId in [firstPanelId, secondPanelId] {
            let transfer = try #require(
                sourceWorkspace.detachSurface(panelId: panelId)
            )
            #expect(
                dock.attachDetachedSurface(
                    transfer,
                    inPane: dockPaneId,
                    focus: false
                ) == panelId
            )
        }

        let coordinator = FeedCoordinator.shared
        let firstTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "first-dock-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "first-dock-attention-request"
                ),
                resolved: (sourceWorkspace.id, firstPanelId),
                tabManager: tabManager
            )
        )
        let secondTarget = try #require(
            coordinator.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "second-dock-attention",
                    hookEventName: .permissionRequest,
                    source: "codex",
                    requestId: "second-dock-attention-request"
                ),
                resolved: (sourceWorkspace.id, secondPanelId),
                tabManager: tabManager
            )
        )
        defer {
            coordinator.concludeBlockingDecisionAttention(firstTarget)
            coordinator.concludeBlockingDecisionAttention(secondTarget)
            dock.closeAllPanels()
            for workspace in [sourceWorkspace, destinationWorkspace]
                where tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let destinationPaneId = try #require(
            destinationWorkspace.bonsplitController.focusedPaneId
        )
        for panelId in [firstPanelId, secondPanelId] {
            let transfer = try #require(dock.detachSurface(panelId: panelId))
            #expect(
                destinationWorkspace.attachDetachedSurface(
                    transfer,
                    inPane: destinationPaneId,
                    focus: false
                ) == panelId
            )
        }

        coordinator.concludeBlockingDecisionAttention(firstTarget)
        #expect(
            ControlSidebarPanelOwner.workspace(destinationWorkspace)
                .statusEntry(key: "codex", panelId: firstPanelId) != nil,
            "Workspace-scoped status must remain while the other moved panel still needs input."
        )

        coordinator.concludeBlockingDecisionAttention(secondTarget)
        #expect(
            ControlSidebarPanelOwner.workspace(destinationWorkspace)
                .statusEntry(key: "codex", panelId: secondPanelId) == nil,
            "The shared workspace badge must clear after the last moved decision ends."
        )
    }

    @Test
    func sessionScopedBuiltInKeysRequireExactProcessGeneration() {
        #expect(
            TerminalController.shared
                .controlSidebarRequiresAgentProcessGeneration(
                    "codex.session-id",
                    target: .workspace(UUID()),
                    panelID: nil
                )
        )
    }

    @Test func terminalAgentContextDoesNotObserveAgentRuntimeMaps() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let changeFlag = ObservationChangeFlag()

        withObservationTracking {
            _ = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        } onChange: {
            changeFlag.mark()
        }

        workspace.recordAgentPID(
            key: "codex.session-c",
            pid: 12_346,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            changeFlag.fired == false,
            "Terminal content must not subscribe to sidebar-only agent runtime map churn."
        )
    }

    @Test func sidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    @Test func sidebarImmediateObservationPublisherDeliversManualTitleChangeSynchronously() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.setCustomTitle("User Edit")

        #expect(
            publishCount == 1,
            "The first immediate-field change after subscribing must reach the sidebar in the same run-loop turn; coalescing may only defer the tail of a burst."
        )
    }

    @Test func sidebarImmediateObservationPublisherCoalescesDescriptionBursts() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        for turn in 0..<20 {
            workspace.customDescription = "Agent Turn \(turn)"
        }

        #expect(
            publishCount == 1,
            "A synchronous burst of immediate fields must deliver only its leading edge immediately."
        )

        // Generous pump so the 50ms trailing emission fires deterministically.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(
            publishCount == 2,
            "A coalesced burst must settle with exactly one trailing emission carrying the latest state."
        )
    }

    @Test func coalesceLatestKeepsLeadingEdgeSynchronousAndEmitsLatestTrailing() {
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // First value models the @Published current-state replay: forwarded
        // synchronously without opening a coalesce window.
        subject.send(1)
        #expect(received == [1])

        // First change is the synchronous leading edge and opens the window.
        subject.send(2)
        #expect(received == [1, 2])

        // Burst inside the window coalesces to the latest value.
        subject.send(3)
        subject.send(4)
        subject.send(5)
        #expect(received == [1, 2])

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(received == [1, 2, 5])

        // After the window closes and the trailing window expires, the next
        // value is synchronous again.
        subject.send(6)
        #expect(received == [1, 2, 5, 6])
    }

    @Test func coalesceLatestDropsStalePendingValueWhenLeadingSupersedesOverdueTrailing() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        subject.send(1) // replay: forwarded, no window
        subject.send(2) // leading edge: opens window
        subject.send(3) // pending trailing value for the open window
        #expect(received == [1, 2])
        #expect(scheduler.scheduledActionCount == 1)

        // The deadline passes WITHOUT the scheduled callback running,
        // modeling a stalled main run loop with an overdue timer.
        scheduler.advance(by: 0.12)
        subject.send(4) // deadline passed: new leading edge must supersede 3

        #expect(
            received == [1, 2, 4],
            "A newer leading value after an overdue deadline must drop the stale pending value."
        )

        scheduler.runScheduledActions()
        #expect(
            received == [1, 2, 4],
            "The overdue trailing callback must not emit the superseded stale value out of order."
        )
    }

    @Test func coalesceLatestDrainsReentrantValueBeforeCompletionWithUnlimitedDemand() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        let subscriber = DemandControlledSubscriber<Int>()
        subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .subscribe(subscriber)
        defer { subscriber.cancel() }

        subscriber.onValue = { value in
            if value == 1 {
                subject.send(2)
                subject.send(completion: .finished)
            }
        }
        subscriber.request(.unlimited)
        subject.send(1)

        #expect(
            subscriber.received == [1, 2],
            "A reentrant value that arrived before completion must drain while unlimited demand remains."
        )
        #expect(subscriber.completionCount == 1)
        #expect(subscriber.receivedValuesAtCompletion == [[1, 2]])
    }

    @Test func coalesceLatestDeliversBufferedValueBeforeCompletionWhenDemandResumes() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        let subscriber = DemandControlledSubscriber<Int>()
        subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .subscribe(subscriber)
        defer { subscriber.cancel() }

        subject.send(1)
        subject.send(completion: .finished)

        #expect(subscriber.received.isEmpty)
        #expect(
            subscriber.completionCount == 0,
            "Completion must wait while the final value is buffered without demand."
        )

        subscriber.request(.max(1))

        #expect(subscriber.received == [1])
        #expect(subscriber.completionCount == 1)
        #expect(subscriber.receivedValuesAtCompletion == [[1]])
    }

    @Test func sidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        #expect(
            publishCount == 0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    @Test func agentLifecycleChangeBumpsRuntimeObservationGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > before,
            "Agent lifecycle changes must notify sidebar rows so the loading spinner updates."
        )
    }

    @Test func redundantAgentLifecycleWriteDoesNotNotifySidebarRows() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        // Re-asserting the same lifecycle value must not churn row refreshes.
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(workspace.sidebarAgentRuntimeObservation.changeGeneration == before)
    }

}
