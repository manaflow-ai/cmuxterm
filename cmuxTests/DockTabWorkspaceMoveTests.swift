import AppKit
import Bonsplit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Dock tab workspace move entrypoints", .serialized)
struct DockTabWorkspaceMoveTests {
    @Test(arguments: [DockScope.global, .workspace])
    func tabDropValidationAndExecutionShareDockOwnership(scope: DockScope) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try withHarness(scope: scope) { app, manager, dock in
                let pane = try #require(dock.bonsplitController.allPaneIds.first)
                let panelID = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: false))
                let tabID = try #require(dock.surfaceId(forPanelId: panelID)).uuid
                let destination = manager.addWorkspace(title: "Drop destination", select: false)

                #expect(app.canMoveBonsplitTab(tabId: tabID, toWorkspace: destination.id))
                #expect(app.canMoveBonsplitTabToNewWorkspace(tabId: tabID))
                #expect(app.workspaceMoveTargets(forBonsplitTab: tabID).map(\.workspaceId)
                    == app.workspaceMoveTargets(forSurface: panelID).map(\.workspaceId))
                #expect(app.moveBonsplitTab(
                    tabId: tabID, toWorkspace: destination.id, focus: false, focusWindow: false
                ))
                #expect(!dock.containsPanel(panelID))
                #expect(destination.panels[panelID] != nil)
                #expect(!app.canMoveBonsplitTab(tabId: UUID(), toWorkspace: destination.id))
                #expect(!app.canMoveBonsplitTab(tabId: tabID, toWorkspace: UUID()))
            }
        }
    }

    @Test(arguments: [DockScope.global, .workspace], [false, true])
    func newWorkspaceAdaptersHonorDestinationAndFocus(scope: DockScope, useTabID: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try withHarness(scope: scope) { app, manager, dock in
                let pane = try #require(dock.bonsplitController.allPaneIds.first)
                let panelID = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: false))
                let tabID = try #require(dock.surfaceId(forPanelId: panelID)).uuid
                let destinationManager = TabManager(autoWelcomeIfNeeded: false)
                let destinationWindowID = UUID()
                app.registerMainWindowContextForTesting(
                    windowId: destinationWindowID, tabManager: destinationManager
                )
                defer {
                    app.unregisterMainWindowContextForTesting(windowId: destinationWindowID)
                    destinationManager.tabs.forEach { $0.teardownAllPanels() }
                }
                let originalSelection = manager.selectedTabId
                let destinationSelection = destinationManager.selectedTabId
                let result: SurfaceNewWorkspaceMoveResult?
                if useTabID {
                    result = app.moveBonsplitTabToNewWorkspace(
                        tabId: tabID, destinationManager: destinationManager,
                        title: "Moved Dock tab", focus: false, focusWindow: false,
                        insertionIndexOverride: 0
                    )
                } else {
                    result = app.moveSurfaceToNewWorkspace(
                        panelId: panelID, destinationManager: destinationManager,
                        title: "Moved Dock tab", focus: false, focusWindow: false,
                        insertionIndexOverride: 0
                    )
                }
                let moved = try #require(result)
                let destination = try #require(destinationManager.tabs.first)
                #expect(destination.id == moved.destinationWorkspaceId)
                #expect(moved.destinationWindowId == destinationWindowID)
                #expect(destination.panels[panelID] != nil)
                #expect(destination.title == "Moved Dock tab")
                #expect(!dock.containsPanel(panelID))
                #expect(manager.selectedTabId == originalSelection)
                #expect(destinationManager.selectedTabId == destinationSelection)
            }
        }
    }

    @Test(arguments: [DockScope.global, .workspace])
    func newWorkspaceMoveRestoresBrowserChromeFocus(scope: DockScope) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try withHarness(scope: scope) { app, manager, dock in
                let pane = try #require(dock.bonsplitController.allPaneIds.first)
                let panelID = try #require(dock.newSurface(kind: .browser, inPane: pane, focus: false))
                let browser = try #require(dock.browserPanel(for: panelID))
                browser.noteWebViewFocused()
                #expect(browser.preferredFocusIntentForActivation() == .browser(.webView))

                #expect(app.moveDockSurfaceToNewWorkspace(
                    sourceDock: dock, panelId: panelID, focus: true, focusWindow: false
                ))
                let destination = try #require(manager.selectedWorkspace)
                #expect(destination.panels[panelID] === browser)
                #expect(destination.focusedPanelId == panelID)
                #expect(browser.preferredFocusIntentForActivation() == .browser(.addressBar))
            }
        }
    }

    private func withHarness(
        scope: DockScope,
        _ body: (AppDelegate, TabManager, DockSplitStore) throws -> Void
    ) throws {
        let previousApp = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        AppDelegate.shared = app
        app.tabManager = manager
        TerminalController.shared.setActiveTabManager(manager)
        app.registerMainWindowContextForTesting(windowId: windowID, tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(previousManager)
            AppDelegate.shared = previousApp
        }
        let workspace = try #require(manager.selectedWorkspace)
        let dock = scope == .global
            ? app.windowDock(forWindowId: windowID)
            : try #require(workspace.dockSplit)
        try body(app, manager, dock)
    }
}
