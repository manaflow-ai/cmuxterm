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

    private func withWindowHistory(
        _ body: (AppDelegate, VaultHistoryEventLog) async throws -> Void
    ) async rethrows {
        _ = NSApplication.shared
        let previousDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let log = VaultHistoryEventLog(store: VaultHistoryEventStore(fileURL: nil), phase: .active)
        let app = AppDelegate(vaultHistoryEventLog: log)
        defer {
            for windowId in app.mainWindowContexts.values.map(\.windowId) {
                _ = app.closeMainWindow(windowId: windowId, recordHistory: false)
            }
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousDelegate
        }
        try await body(app, log)
    }

    private func event(id: String) -> VaultHistoryEvent {
        VaultHistoryEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .workspaceCreated,
            title: id
        )
    }
}
