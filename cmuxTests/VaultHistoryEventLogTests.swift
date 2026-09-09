import AppKit
import CmuxVaultHistory
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct VaultHistoryLaunchTransactionTests {
    @Test(arguments: [false, true], [VaultHistoryRecordingPhase.launching, .restoring])
    func discardedLaunchWindowDoesNotPublishEvents(
        discardAfterCommit: Bool,
        phaseAtCommit: VaultHistoryRecordingPhase
    ) async {
        let log = VaultHistoryEventLog(store: VaultHistoryEventStore(fileURL: nil))
        let discardedWindowId = UUID()
        let retainedWindowId = UUID()
        for (id, windowId) in [("discarded", discardedWindowId), ("retained", retainedWindowId)] {
            log.beginWindowCreation(windowId: windowId)
            log.record(VaultHistoryEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                kind: .windowOpened,
                title: id,
                subject: VaultHistorySubject(windowId: windowId)
            ))
        }
        if !discardAfterCommit {
            log.discardWindowCreation(windowId: discardedWindowId)
        }
        log.transition(to: phaseAtCommit)
        log.commitWindowCreation(windowId: discardedWindowId)
        log.commitWindowCreation(windowId: retainedWindowId)
        log.transition(to: .restoring)
        if discardAfterCommit {
            log.discardWindowCreation(windowId: discardedWindowId)
        }
        log.transition(to: .active)
        await log.flushPendingRecords()

        #expect(await log.recentEvents().map(\.id) == ["retained"])
        #expect(log.revision == 1)
    }

    @Test(
        arguments: [VaultHistoryRecordingPhase.launching, .active],
        [VaultHistoryRecordingPhase.restoring, .terminating]
    )
    func committedSnapshotsSurvivePhaseChanges(
        initialPhase: VaultHistoryRecordingPhase,
        phaseAtCommit: VaultHistoryRecordingPhase
    ) async {
        let log = VaultHistoryEventLog(store: VaultHistoryEventStore(fileURL: nil), phase: initialPhase)
        let windowId = UUID()
        let acceptedEvent = VaultHistoryEvent(
            id: "accepted",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .windowOpened,
            title: "Original snapshot",
            subject: VaultHistorySubject(windowId: windowId)
        )
        log.beginWindowCreation(windowId: windowId)
        log.record(acceptedEvent)
        log.transition(to: phaseAtCommit)
        log.record(VaultHistoryEvent(
            id: "suppressed",
            timestamp: acceptedEvent.timestamp.addingTimeInterval(1),
            kind: .windowClosed,
            title: "Restore or shutdown must remain silent",
            subject: acceptedEvent.subject
        ))
        log.commitWindowCreation(windowId: windowId)
        log.commitWindowCreation(windowId: windowId)

        #expect(log.hasPendingRecords)
        if phaseAtCommit == .restoring {
            await log.flushPendingRecords()
            #expect(await log.recentEvents().isEmpty)
            #expect(log.revision == 0)
            log.transition(to: .active)
        }
        await log.flushPendingRecords()
        // Repeated lifecycle notifications must not replay an accepted batch.
        log.transition(to: .terminating)
        await log.flushPendingRecords()

        #expect(await log.recentEvents() == [acceptedEvent])
        #expect(log.revision == 1)
        #expect(!log.hasPendingRecords)
    }

    @Test(arguments: [VaultHistoryRecordingPhase.restoring, .terminating])
    func transactionsStartedDuringSuppressionDoNotPublishEvents(phase: VaultHistoryRecordingPhase) async {
        let log = VaultHistoryEventLog(store: VaultHistoryEventStore(fileURL: nil), phase: phase)
        let windowId = UUID()
        log.beginWindowCreation(windowId: windowId)
        log.record(VaultHistoryEvent(
            id: "suppressed",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .windowOpened,
            title: "Programmatic window",
            subject: VaultHistorySubject(windowId: windowId)
        ))
        log.transition(to: .active)
        log.commitWindowCreation(windowId: windowId)
        await log.flushPendingRecords()

        #expect(await log.recentEvents().isEmpty)
        #expect(log.revision == 0)
        #expect(!log.hasPendingRecords)
    }
}

@MainActor
@Suite(.serialized) struct VaultHistoryEventLogTests {
    @Test func lifecyclePhasesOnlyAcceptActiveEvents() async {
        let store = VaultHistoryEventStore(fileURL: nil)
        let log = VaultHistoryEventLog(store: store)

        log.record(event(id: "launch"))
        log.transition(to: .active)
        log.record(event(id: "active"))
        await log.flushPendingRecords()
        log.transition(to: .restoring)
        log.record(event(id: "restore"))
        log.transition(to: .terminating)
        log.record(event(id: "terminate"))
        await log.flushPendingRecords()

        #expect(log.revision == 1)
        #expect(await log.recentEvents().map(\.id) == ["active"])
    }

    @Test func pendingWindowEventsStageDuringLaunchUntilCommitted() async {
        let store = VaultHistoryEventStore(fileURL: nil)
        let log = VaultHistoryEventLog(store: store, phase: .launching)
        let windowId = UUID()

        log.beginWindowCreation(windowId: windowId)
        log.record(event(id: "launch", windowId: windowId))
        await log.flushPendingRecords()
        #expect(await log.recentEvents().isEmpty)

        log.transition(to: .active)
        log.commitWindowCreation(windowId: windowId)
        await log.flushPendingRecords()
        #expect(await log.recentEvents().map(\.id) == ["launch"])
    }

    @Test func committedWindowEventsRemainStagedUntilLaunchCompletes() async {
        let store = VaultHistoryEventStore(fileURL: nil)
        let log = VaultHistoryEventLog(store: store, phase: .launching)
        let windowId = UUID()

        log.beginWindowCreation(windowId: windowId)
        log.record(event(id: "launch", windowId: windowId))
        log.commitWindowCreation(windowId: windowId)
        await log.flushPendingRecords()
        #expect(await log.recentEvents().isEmpty)

        log.transition(to: .active)
        await log.flushPendingRecords()
        #expect(await log.recentEvents().map(\.id) == ["launch"])
    }

    @Test(arguments: [VaultHistoryRecordingPhase.launching, .restoring])
    func terminatingFlushRetainsCommittedLaunchEvents(phaseBeforeQuit: VaultHistoryRecordingPhase) async {
        let log = VaultHistoryEventLog(store: VaultHistoryEventStore(fileURL: nil))
        let retainedWindowId = UUID()
        let uncommittedWindowId = UUID()
        log.beginWindowCreation(windowId: retainedWindowId)
        log.record(event(id: "retained", windowId: retainedWindowId))
        log.commitWindowCreation(windowId: retainedWindowId)
        log.beginWindowCreation(windowId: uncommittedWindowId)
        log.record(event(id: "uncommitted", windowId: uncommittedWindowId))
        log.transition(to: phaseBeforeQuit)

        #expect(log.hasPendingRecords)
        log.transition(to: .terminating)
        log.record(event(id: "shutdown"))
        await log.flushPendingRecords()

        #expect(await log.recentEvents().map(\.id) == ["retained"])
        #expect(log.revision == 1)
        #expect(!log.hasPendingRecords)
        #expect(log.phase == .terminating)
    }

    @Test func startupRestoreDiscardsInitialWindowHistoryAfterRestoreCompletes() async throws {
        try await withWindowHistory(initialPhase: .launching) { app, log in
            let restoredWindowSnapshot = SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: nil,
                    workspaces: []
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
            app.setStartupSessionSnapshotForTesting(AppSessionSnapshot(
                version: SessionSnapshotSchema.currentVersion,
                createdAt: Date().timeIntervalSince1970,
                windows: [restoredWindowSnapshot]
            ))

            _ = app.createMainWindow(shouldActivate: false)
            await log.flushPendingRecords()

            #expect(await log.recentEvents().isEmpty)
        }
    }

    @Test(arguments: ["nativeClose", "close", "discard"], [true, false])
    func startupRestoreRetriesAfterDeferredWindowCloses(
        closePath: String,
        replacementExistsBeforeClose: Bool
    ) async throws {
        var signingSecretReady = false
        var resumeCallbacks: [@MainActor @Sendable () -> Void] = []
        try await withWindowHistory(
            initialPhase: .launching,
            startupSessionRestoreDeferral: { resume in
                guard !signingSecretReady else { return false }
                resumeCallbacks.append(resume)
                return true
            }
        ) { app, log in
            let restoredWindowSnapshot = SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: nil,
                    workspaces: []
                ),
                sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
            )
            app.setStartupSessionSnapshotForTesting(AppSessionSnapshot(
                version: SessionSnapshotSchema.currentVersion,
                createdAt: Date().timeIntervalSince1970,
                windows: [restoredWindowSnapshot]
            ))

            let firstWindowId = app.createMainWindow(shouldActivate: false)
            let firstWindow = try #require(app.mainWindowContexts.values.first?.window)
            // AppKit can retain a closed window. A live weak reference must not
            // let its stale callback consume the replacement's restore.
            defer { withExtendedLifetime(firstWindow) {} }
            #expect(resumeCallbacks.count == 1)
            let existingReplacementId = replacementExistsBeforeClose
                ? app.createMainWindow(shouldActivate: false) : nil
            switch closePath {
            case "nativeClose":
                firstWindow.close()
            case "discard":
                app.discardMainWindowWithoutClosedHistory(windowId: firstWindowId)
            default:
                #expect(app.closeMainWindow(windowId: firstWindowId, recordHistory: false))
            }
            #expect(app.tabManagerFor(windowId: firstWindowId) == nil)

            let replacementId = existingReplacementId ?? app.createMainWindow(shouldActivate: false)
            let replacement = try #require(app.mainWindowContexts.values.first { $0.windowId == replacementId })
            let replacementWorkspaceId = try #require(replacement.tabManager.tabs.first?.id)
            #expect(resumeCallbacks.count == 1)
            #expect(!app.didAttemptStartupSessionRestore)
            await log.flushPendingRecords()
            let interactiveEvents = await log.recentEvents()
            #expect(interactiveEvents.filter { $0.kind == .windowOpened }.map(\.subject.windowId) == [replacementId])
            #expect(interactiveEvents.filter { $0.kind == .workspaceCreated }.map(\.subject.workspaceId)
                == [replacementWorkspaceId])

            signingSecretReady = true
            let resume = try #require(resumeCallbacks.first)
            resume()
            #expect(app.didAttemptStartupSessionRestore)
            #expect(!replacement.sidebarState.isVisible)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().map(\.id) == interactiveEvents.map(\.id))

            // Readiness notifications are safe to deliver more than once.
            replacement.sidebarState.isVisible = true
            resume()
            #expect(replacement.sidebarState.isVisible)
        }
    }

    @Test func startupRestoreWaitsForAWindowAfterReadinessArrives() async throws {
        var signingSecretReady = false
        var resume: (@MainActor @Sendable () -> Void)?
        try await withWindowHistory(
            initialPhase: .launching,
            startupSessionRestoreDeferral: { continuation in
                guard !signingSecretReady else { return false }
                resume = continuation
                return true
            }
        ) { app, log in
            let firstWindowId = app.createMainWindow(shouldActivate: false)
            let firstWindow = try #require(app.mainWindowContexts.values.first?.window)
            defer { withExtendedLifetime(firstWindow) {} }
            #expect(app.closeMainWindow(windowId: firstWindowId, recordHistory: false))
            signingSecretReady = true
            let continuation = try #require(resume)
            continuation()
            #expect(!app.didAttemptStartupSessionRestore)

            let replacementId = app.createMainWindow(shouldActivate: false)
            #expect(app.didAttemptStartupSessionRestore)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().filter { $0.kind == .windowOpened }.map(\.subject.windowId)
                == [replacementId])
        }
    }

    @Test func revisionChangesOnlyAfterAcceptedPersistence() async {
        let acceptedStore = VaultHistoryEventStore(fileURL: nil)
        let acceptedLog = VaultHistoryEventLog(store: acceptedStore, phase: .active)

        acceptedLog.record(event(id: "accepted"))
        #expect(acceptedLog.hasPendingRecords)
        #expect(acceptedLog.revision == 0)
        await acceptedLog.flushPendingRecords()
        #expect(!acceptedLog.hasPendingRecords)
        #expect(acceptedLog.revision == 1)
        #expect(await acceptedLog.recentEvents().map(\.id) == ["accepted"])

        let rejectedStore = VaultHistoryEventStore(
            fileURL: URL(fileURLWithPath: "/dev/null/vault-history.jsonl")
        )
        let rejectedLog = VaultHistoryEventLog(store: rejectedStore, phase: .active)
        rejectedLog.record(event(id: "rejected"))
        #expect(rejectedLog.hasPendingRecords)
        await rejectedLog.flushPendingRecords()

        #expect(!rejectedLog.hasPendingRecords)
        #expect(rejectedLog.revision == 0)
        #expect(await rejectedLog.recentEvents().isEmpty)
    }

    @Test func interactiveHistoryDoesNotWaitForStartupSigningSecret() async throws {
        var signingSecretReady = false
        var resumeCallbacks: [@MainActor @Sendable () -> Void] = []
        try await withWindowHistory(
            initialPhase: .launching,
            startupSessionRestoreDeferral: { resume in
                guard !signingSecretReady else { return false }
                resumeCallbacks.append(resume)
                return true
            }
        ) { app, log in
            let firstWindowId = app.createMainWindow(shouldActivate: false)
            let manager = try #require(app.tabManagerFor(windowId: firstWindowId))
            let startupWorkspace = try #require(manager.selectedWorkspace)
            #expect(!app.didAttemptStartupSessionRestore)
            #expect(log.phase == .active)

            let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            #expect(manager.setCustomTitle(tabId: workspace.id, title: "While restore is waiting"))
            manager.closeWorkspace(workspace)
            let secondWindowId = app.createMainWindow(shouldActivate: false)
            let secondWorkspace = try #require(app.tabManagerFor(windowId: secondWindowId)?.selectedWorkspace)
            await log.flushPendingRecords()

            let events = await log.recentEvents()
            #expect(events.count == 5)
            #expect(events.filter { $0.kind == .windowOpened }.map(\.subject.windowId) == [secondWindowId])
            #expect(Set(events.filter { $0.kind == .workspaceCreated }.compactMap(\.subject.workspaceId))
                == Set([workspace.id, secondWorkspace.id]))
            #expect(events.filter { $0.kind == .workspaceRenamed }.map(\.subject.workspaceId) == [workspace.id])
            #expect(events.filter { $0.kind == .workspaceClosed }.map(\.subject.workspaceId) == [workspace.id])
            #expect(!events.contains { $0.subject.workspaceId == startupWorkspace.id })
            #expect(!app.didAttemptStartupSessionRestore)

            // The external callback may be delayed indefinitely. When it does
            // arrive, the real startup continuation must not add restore noise.
            let resume = try #require(resumeCallbacks.first)
            signingSecretReady = true
            resume()
            #expect(app.didAttemptStartupSessionRestore)
            #expect(log.phase == .active)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().map(\.id) == events.map(\.id))

            app.isApplyingSessionRestore = true
            #expect(log.phase == .restoring)
            #expect(manager.setCustomTitle(tabId: startupWorkspace.id, title: "Restored title"))
            app.isApplyingSessionRestore = false
            #expect(log.phase == .active)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().map(\.id) == events.map(\.id))
        }
    }

    @Test func workspaceRecordingDistinguishesSemanticCreationFromBootstrapAndRestore() async {
        let store = VaultHistoryEventStore(fileURL: nil)
        let log = VaultHistoryEventLog(store: store, phase: .active)
        let windowId = UUID()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            windowId: windowId,
            vaultHistoryEventLog: log,
            initialWorkspaceHistoryContext: .bootstrap
        )

        _ = manager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false,
            vaultHistoryContext: .restoration
        )
        _ = manager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false,
            vaultHistoryContext: .structuralReplacement
        )
        let created = manager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false,
            vaultHistoryContext: .semanticCreation
        )
        await log.flushPendingRecords()

        let events = await log.recentEvents()
        #expect(events.count == 1)
        #expect(events.first?.kind == .workspaceCreated)
        #expect(events.first?.subject.workspaceId == created.id)
        #expect(events.first?.subject.windowId == windowId)
    }

    @Test func renameRecordingSurvivesSynchronousWorkspaceRemovalObserver() async throws {
        let store = VaultHistoryEventStore(fileURL: nil)
        let log = VaultHistoryEventLog(store: store, phase: .active)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            vaultHistoryEventLog: log,
            initialWorkspaceHistoryContext: .bootstrap
        )
        let renamedWorkspace = try #require(manager.selectedWorkspace)
        _ = try #require(manager.addWorkspaceIfActive(
            select: false,
            autoWelcomeIfNeeded: false,
            vaultHistoryContext: .structuralReplacement
        ))

        let observer = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { _ in
            manager.closeWorkspace(renamedWorkspace, recordHistory: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(manager.setCustomTitle(tabId: renamedWorkspace.id, title: "Renamed"))
        await log.flushPendingRecords()

        let renameEvent = try #require(
            await log.recentEvents().first(where: { $0.kind == .workspaceRenamed })
        )
        #expect(renameEvent.subject.workspaceId == renamedWorkspace.id)
        #expect(renameEvent.title == "Renamed")
    }

    @Test func movingWorkspaceToNewWindowDoesNotRecordItsTemporaryWorkspace() async throws {
        try await withWindowHistory { app, log in
            let sourceWindowId = app.createMainWindow(shouldActivate: false)
            let source = try #require(app.tabManagerFor(windowId: sourceWindowId))
            let workspace = try #require(source.selectedWorkspace)

            let destinationId = try #require(app.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: false))
            let destination = try #require(app.tabManagerFor(windowId: destinationId))
            #expect(destination.tabs.map(\.id) == [workspace.id])
            await log.flushPendingRecords()

            let creations = await log.recentEvents().filter { $0.kind == .workspaceCreated }
            #expect(creations.map(\.subject.workspaceId) == [workspace.id])
            let openings = await log.recentEvents().filter { $0.kind == .windowOpened }
            #expect(Set(openings.compactMap(\.subject.windowId)) == Set([sourceWindowId, destinationId]))
            #expect(openings.count == 2)
        }
    }

    @Test func failedWorkspaceMoveDoesNotRecordItsDiscardedWindow() async throws {
        try await withWindowHistory { app, log in
            #expect(app.moveWorkspaceToNewWindow(workspaceId: UUID(), focus: false) == nil)
            #expect(app.mainWindowContexts.isEmpty)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().isEmpty)
        }
    }

    @Test func discardedBootstrapWindowDoesNotPublishAnyPendingLifecycleEvents() async throws {
        try await withWindowHistory { app, log in
            let windowId = app.createMainWindow(
                initialWorkspaceHistoryContext: .bootstrap,
                shouldActivate: false
            )
            let manager = try #require(app.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.addWorkspaceIfActive(select: true, autoWelcomeIfNeeded: false))
            #expect(manager.setCustomTitle(tabId: workspace.id, title: "Uncommitted"))
            await log.flushPendingRecords()
            #expect(await log.recentEvents().isEmpty)

            app.discardMainWindowWithoutClosedHistory(windowId: windowId)
            #expect(app.mainWindowContexts.isEmpty)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func closedWindowReopenRecordsOnlyUsableRestoredWindows(restoreSucceeds: Bool) async throws {
        try await withWindowHistory { app, log in
            let sourceId = app.createMainWindow(shouldActivate: false)
            let manager = try #require(app.tabManagerFor(windowId: sourceId))
            let workspace = try #require(manager.selectedWorkspace)
            var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
            if !restoreSucceeds {
                var panel = try #require(workspaceSnapshot.panels.first)
                // This panel advertises restorable content, but lacks the
                // payload needed to recreate it. Restoration returns no map.
                panel.type = .markdown
                panel.terminal = nil
                panel.markdown = nil
                workspaceSnapshot.panels = [panel]
                workspaceSnapshot.layout = .pane(SessionPaneLayoutSnapshot(
                    panelIds: [panel.id], selectedPanelId: panel.id
                ))
            }
            let snapshot = SessionWindowSnapshot(
                windowId: sourceId,
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspaceSnapshot]),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
            #expect(snapshot.hasRestorablePanels)
            let record = ClosedItemHistoryRecord(entry: .window(ClosedWindowHistoryEntry(snapshot: snapshot)))
            ClosedItemHistoryStore.shared.push(record)
            defer { _ = ClosedItemHistoryStore.shared.removeRecord(id: record.id) }
            #expect(app.closeMainWindow(windowId: sourceId, recordHistory: false))
            await log.flushPendingRecords()
            let priorIds = Set(await log.recentEvents().map(\.id))

            // Exercise the actual reopen/validation/discard path, including
            // the fallback workspace created when panel restoration fails.
            #expect(app.reopenClosedHistoryItem(id: record.id, shouldActivate: false) == restoreSucceeds)
            #expect(app.mainWindowContexts.count == (restoreSucceeds ? 1 : 0))
            await log.flushPendingRecords()
            let reopenedEvents = await log.recentEvents().filter { !priorIds.contains($0.id) }
            #expect(reopenedEvents.map(\.kind) == (restoreSucceeds ? [.windowOpened] : []))
        }
    }

    @Test(arguments: ["cmux.cloudVM", "cmux.newWorkspace", "cmux.newAgentChat"])
    func configuredWorkspaceActionRecordsOnlyItsRetainedWorkspace(actionId: String) async throws {
        var createdId: UUID?
        try await withWindowHistory(
            configuredActionId: actionId,
            configuredActionExecutor: { action, context, _, onExecuted, onCompletion, _ in
                guard let workspace = context.tabManager.addWorkspaceIfActive(
                    initialSurface: .cloudVMLoading,
                    select: true,
                    autoWelcomeIfNeeded: false
                ) else { return false }
                createdId = workspace.id
                onExecuted?()
                if action.action == .builtIn(.cloudVM) {
                    onCompletion?(.init(terminationStatus: 0, output: "", workspaceId: workspace.id))
                }
                return true
            }
        ) { app, log in
            #expect(app.performNewWorkspaceAction())
            let context = try #require(app.mainWindowContexts.values.first)
            let retainedId = try #require(createdId)
            #expect(context.tabManager.tabs.map(\.id) == [retainedId])
            await log.flushPendingRecords()
            let events = await log.recentEvents()
            #expect(events.filter { $0.kind == .workspaceCreated }.map(\.subject.workspaceId) == [createdId])
            #expect(events.filter { $0.kind == .windowOpened }.count == 1)
            #expect(!events.contains { $0.kind == .workspaceClosed })
        }
    }

    @Test(arguments: [true, false])
    func delayedCloudVMCompletionRecordsTheActualRetainedWorkspace(succeeded: Bool) async throws {
        var complete: ((CloudVMActionLauncher.Completion) -> Void)?
        try await withWindowHistory(
            configuredActionId: "cmux.cloudVM",
            configuredActionExecutor: { _, _, _, onExecuted, onCompletion, _ in
                complete = onCompletion
                onExecuted?()
                return true
            }
        ) { app, log in
            #expect(app.performNewWorkspaceAction())
            let context = try #require(app.mainWindowContexts.values.first)
            let initialWorkspace = try #require(context.tabManager.selectedWorkspace)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().filter { $0.kind == .workspaceCreated }.isEmpty)

            let result = try #require(succeeded ? context.tabManager.addWorkspaceIfActive(
                initialSurface: .cloudVMLoading,
                select: true,
                autoWelcomeIfNeeded: false
            ) : initialWorkspace)
            let completion = try #require(complete)
            completion(.init(terminationStatus: succeeded ? 0 : 1, output: "", workspaceId: succeeded ? result.id : nil))
            #expect(context.tabManager.tabs.map(\.id) == [result.id])
            await log.flushPendingRecords()
            let events = await log.recentEvents()
            #expect(events.filter { $0.kind == .workspaceCreated }.map(\.subject.workspaceId) == [result.id])
            #expect(events.filter { $0.kind == .windowOpened }.count == 1)
        }
    }

    @Test func configuredInWorkspaceActionRecordsItsRetainedInitialWorkspace() async throws {
        try await withWindowHistory(
            configuredActionId: "cmux.newTerminal",
            configuredActionExecutor: { _, _, _, onExecuted, _, _ in
                onExecuted?()
                return true
            }
        ) { app, log in
            #expect(app.performNewWorkspaceAction())
            let context = try #require(app.mainWindowContexts.values.first)
            let workspace = try #require(context.tabManager.selectedWorkspace)
            await log.flushPendingRecords()
            let events = await log.recentEvents()
            #expect(events.filter { $0.kind == .workspaceCreated }.map(\.subject.workspaceId) == [workspace.id])
        }
    }

    @Test func cancelledConfiguredActionRecordsTheWorkspaceThatRemains() async throws {
        var complete: ((Bool) -> Void)?
        try await withWindowHistory(
            configuredActionId: "cmux.newWorkspace",
            configuredActionExecutor: { _, _, _, _, _, onCompleted in
                complete = onCompleted
                return true
            }
        ) { app, log in
            #expect(app.performNewWorkspaceAction())
            let context = try #require(app.mainWindowContexts.values.first)
            let initialWorkspace = try #require(context.tabManager.selectedWorkspace)
            await log.flushPendingRecords()
            #expect(await log.recentEvents().isEmpty)

            let completion = try #require(complete)
            completion(false)
            await log.flushPendingRecords()

            let events = await log.recentEvents()
            #expect(events.filter { $0.kind == .windowOpened }.count == 1)
            #expect(events.filter { $0.kind == .workspaceCreated }.map(\.subject.workspaceId) == [initialWorkspace.id])
        }
    }

    @Test(arguments: ["cmux.splitRight", "cmux.splitDown"])
    func suppressedConfiguredSplitCompletesWithoutExecuting(actionId: String) async throws {
        try await withWindowHistory(configuredActionId: actionId) { app, _ in
            let windowId = app.createMainWindow(shouldActivate: false)
            let context = try #require(app.mainWindowContexts.values.first { $0.windowId == windowId })
            let window = try #require(context.window)
            let workspace = try #require(context.tabManager.selectedWorkspace)
            let terminal = try #require(workspace.focusedTerminalInputTarget()?.panel)
            let action = try #require(context.cmuxConfigStore?.resolvedNewWorkspaceAction())
            let previousRoutingWindow = app.shortcutRoutingKeyWindow
            let wasHidden = terminal.hostedView.isHidden
            defer {
                terminal.hostedView.isHidden = wasHidden
                app.debugSetShortcutRoutingFocusedWindowForTesting(previousRoutingWindow)
            }
            terminal.hostedView.isHidden = true
            #expect(window.makeFirstResponder(nil))
            app.debugSetShortcutRoutingFocusedWindowForTesting(window)
            try #require(app.shouldSuppressSplitShortcutForTransientTerminalFocusState(
                tabManager: context.tabManager
            ))

            let originalPanelIds = Set(workspace.panels.keys)
            var executionCount = 0
            var completions: [Bool] = []
            #expect(app.executeConfiguredCmuxAction(
                action,
                context: context,
                preferredWindow: window,
                onExecuted: { executionCount += 1 },
                onCompleted: { completions.append($0) }
            ))

            #expect(executionCount == 0)
            #expect(completions == [false])
            #expect(Set(workspace.panels.keys) == originalPanelIds)
        }
    }

    @Test func browserWorkspaceWithNoWindowsRecordsOnlyTheBrowserWorkspace() async throws {
        try await withWindowHistory { app, log in
            #expect(app.performNewBrowserWorkspaceAction())
            let context = try #require(app.mainWindowContexts.values.first)
            let workspace = try #require(context.tabManager.selectedWorkspace)
            #expect(context.tabManager.tabs.count == 1)
            #expect(workspace.panels.values.contains { $0 is BrowserPanel })
            await log.flushPendingRecords()

            let creations = await log.recentEvents().filter { $0.kind == .workspaceCreated }
            #expect(creations.map(\.subject.workspaceId) == [workspace.id])
        }
    }

    @Test func ordinaryNewWindowStillRecordsItsInitialWorkspace() async throws {
        try await withWindowHistory { app, log in
            let windowId = app.createMainWindow(shouldActivate: false)
            let workspace = try #require(app.tabManagerFor(windowId: windowId)?.selectedWorkspace)
            await log.flushPendingRecords()

            let creations = await log.recentEvents().filter { $0.kind == .workspaceCreated }
            #expect(creations.map(\.subject.workspaceId) == [workspace.id])
            #expect(creations.first?.subject.windowId == windowId)
        }
    }

    @Test func terminalWorkspaceWithNoWindowsRecordsItsRetainedInitialWorkspace() async throws {
        try await withWindowHistory { app, log in
            #expect(app.performNewWorkspaceAction())
            let context = try #require(app.mainWindowContexts.values.first)
            let workspace = try #require(context.tabManager.selectedWorkspace)
            #expect(context.tabManager.tabs.count == 1)
            await log.flushPendingRecords()

            let creations = await log.recentEvents().filter { $0.kind == .workspaceCreated }
            #expect(creations.map(\.subject.workspaceId) == [workspace.id])
        }
    }

    @Test func suppressedWindowCloseDoesNotRecordWorkspaceClosures() async throws {
        try await withWindowHistory { app, log in
            let windowId = app.createMainWindow(
                initialWorkspaceHistoryContext: .bootstrap,
                shouldActivate: false
            )
            #expect(app.closeMainWindow(windowId: windowId, recordHistory: false))
            await log.flushPendingRecords()

            let events = await log.recentEvents()
            #expect(events.isEmpty)
        }
    }

    @Test func ordinaryWindowCloseRecordsEveryWorkspace() async throws {
        try await withWindowHistory { app, log in
            let windowId = app.createMainWindow(shouldActivate: false)
            let manager = try #require(app.tabManagerFor(windowId: windowId))
            let initial = try #require(manager.selectedWorkspace)
            let additional = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            #expect(app.closeMainWindow(windowId: windowId))
            await log.flushPendingRecords()

            let events = await log.recentEvents()
            let closedIds = events.filter { $0.kind == .workspaceClosed }.compactMap(\.subject.workspaceId)
            #expect(Set(closedIds) == Set([initial.id, additional.id]))
            #expect(closedIds.count == 2)
            #expect(events.filter { $0.kind == .windowClosed }.count == 1)
        }
    }

    private func withWindowHistory(
        configuredActionId: String? = nil,
        configuredActionExecutor: AppDelegate.ConfiguredActionExecutor? = nil,
        initialPhase: VaultHistoryRecordingPhase = .active,
        startupSessionRestoreDeferral: AppDelegate.StartupSessionRestoreDeferral? = nil,
        _ body: (AppDelegate, VaultHistoryEventLog) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-history-actions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("cmux.json")
        let config = configuredActionId.map { "{\"ui\":{\"newWorkspace\":{\"action\":\"\($0)\"}}}" } ?? "{}"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let previousDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let log = VaultHistoryEventLog(store: VaultHistoryEventStore(fileURL: nil), phase: initialPhase)
            let app = AppDelegate(
                vaultHistoryEventLog: log,
                windowConfigStoreFactory: { CmuxConfigStore(globalConfigPath: configURL.path) },
                configuredActionExecutor: configuredActionExecutor,
                startupSessionRestoreDeferral: startupSessionRestoreDeferral ?? { _ in false }
            )
            defer {
                for windowId in app.mainWindowContexts.values.map(\.windowId) {
                    _ = app.closeMainWindow(windowId: windowId, recordHistory: false)
                }
                TerminalController.shared.setActiveTabManager(previousManager)
                AppDelegate.shared = previousDelegate
            }
            try await body(app, log)
        }
    }

    private func event(id: String, windowId: UUID? = nil) -> VaultHistoryEvent {
        VaultHistoryEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .workspaceCreated,
            title: id,
            subject: VaultHistorySubject(windowId: windowId)
        )
    }
}
