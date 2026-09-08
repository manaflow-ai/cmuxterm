import Foundation
import CmuxSettings

struct SurfaceNewWorkspaceMoveResult {
    let sourceWindowId: UUID
    let sourceWorkspaceId: UUID
    let destinationWindowId: UUID?
    let destinationWorkspaceId: UUID
    let surfaceId: UUID
    let paneId: UUID?
}

@MainActor
extension AppDelegate {
    /// Resolves a live Dock owner for a panel id without creating a Dock.
    /// Native terminal context menus use panel ids, so they must share the
    /// same owner lookup as tab-strip, shortcut, and command-palette actions.
    func dockContainingSurface(_ panelId: UUID) -> DockSplitStore? {
        DockSplitStore.liveStores.first {
            !$0.isRetired && $0.containsPanel(panelId)
        }
    }

    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        if let dock = dockContainingSurface(panelId) {
            return dock.panels[panelId] != nil
                && dockReferenceTabManager(for: dock) != nil
        }
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              sourceWorkspace.panels[panelId] != nil else {
            return false
        }
        return sourceWorkspace.panels.count > 1
    }

    func canMoveBonsplitTabToNewWorkspace(tabId: UUID) -> Bool {
        guard let source = locateContainerSurface(tabId: tabId) else { return false }
        switch source {
        case .workspace(_, _, let panelId, _), .dock(_, let panelId):
            return canMoveSurfaceToNewWorkspace(panelId: panelId)
        }
    }

    func canMoveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId),
              destinationManager.tabs.contains(where: { $0.id == targetWorkspaceId }),
              let source = locateContainerSurface(tabId: tabId) else {
            return false
        }
        switch source {
        case .workspace(_, let sourceWorkspace, let panelId, _):
            return sourceWorkspace.panels[panelId] != nil
        case .dock(let dock, let panelId):
            return dock.panels[panelId] != nil &&
                dockReferenceTabManager(for: dock) != nil
        }
    }

    func workspaceMoveTargets(forSurface panelId: UUID) -> [WorkspaceMoveTarget] {
        if let dock = dockContainingSurface(panelId) {
            guard let referenceManager = dockReferenceTabManager(for: dock) else {
                return []
            }
            let referenceWindowId = windowId(for: referenceManager)
            let excludedWorkspaceId: UUID? = dock.scope == .workspace
                ? dock.workspaceId
                : nil
            return workspaceMoveTargets(
                excludingWorkspaceId: excludedWorkspaceId,
                referenceWindowId: referenceWindowId
            )
        }
        guard let source = locateSurface(surfaceId: panelId) else { return [] }
        return workspaceMoveTargets(
            excludingWorkspaceId: source.workspaceId,
            referenceWindowId: source.windowId
        )
    }

    func workspaceMoveTargets(forBonsplitTab tabId: UUID) -> [WorkspaceMoveTarget] {
        guard let source = locateContainerSurface(tabId: tabId) else { return [] }
        let panelId: UUID
        switch source {
        case .workspace(_, _, let locatedPanelId, _), .dock(_, let locatedPanelId):
            panelId = locatedPanelId
        }
        return workspaceMoveTargets(forSurface: panelId)
    }

    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateContainerSurface(tabId: tabId) else { return nil }
        switch source {
        case .workspace(_, _, let panelId, _):
            return moveSurfaceToNewWorkspace(
                panelId: panelId,
                destinationManager: destinationManager,
                title: title,
                focus: focus,
                focusWindow: focusWindow,
                placementOverride: placementOverride,
                insertionIndexOverride: insertionIndexOverride
            )
        case .dock(let dock, let panelId):
            return moveDockSurfaceToNewWorkspaceResult(
                sourceDock: dock,
                panelId: panelId,
                destinationManager: destinationManager,
                title: title,
                focus: focus,
                focusWindow: focusWindow,
                placementOverride: placementOverride,
                insertionIndexOverride: insertionIndexOverride
            )
        }
    }

    @discardableResult
    func moveSurfaceToNewWorkspace(
        panelId: UUID,
        destinationManager: TabManager? = nil,
        title: String? = nil,
        focus: Bool = true,
        focusWindow: Bool = true,
        placementOverride: WorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil
    ) -> SurfaceNewWorkspaceMoveResult? {
        guard let source = locateSurface(surfaceId: panelId),
              let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }),
              let sourcePanel = sourceWorkspace.panels[panelId],
              sourceWorkspace.panels.count > 1 else {
            return nil
        }

        let targetManager = destinationManager ?? source.tabManager
        let hasExplicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasExplicitTitle {
            source.tabManager.flushPendingPanelTitleUpdatesForWorkspaceSnapshot()
        }
        let destinationTitle = titleForDetachedWorkspace(
            explicitTitle: title,
            workspace: sourceWorkspace,
            panelId: panelId,
            panel: sourcePanel
        )
        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        let activationIntent = focusIntentForNewWorkspaceMove(panel: sourcePanel)
        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else { return nil }

        guard let destinationWorkspace = targetManager.addWorkspace(
            fromDetachedSurface: detached,
            title: destinationTitle,
            titleSource: hasExplicitTitle ? .user : .auto,
            select: false,
            placementOverride: placementOverride,
            insertionIndexOverride: insertionIndexOverride,
            focusIntent: activationIntent
        ) else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
            return nil
        }

        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: targetManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            targetManager.focusTab(
                destinationWorkspace.id,
                surfaceId: panelId,
                suppressFlash: true,
                focusIntent: activationIntent
            )
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: destinationWorkspace.id,
                    destinationPanelId: panelId,
                    destinationManager: targetManager
                )
            }
        }

        return SurfaceNewWorkspaceMoveResult(
            sourceWindowId: source.windowId,
            sourceWorkspaceId: source.workspaceId,
            destinationWindowId: windowId(for: targetManager),
            destinationWorkspaceId: destinationWorkspace.id,
            surfaceId: panelId,
            paneId: destinationWorkspace.paneId(forPanelId: panelId)?.id
        )
    }

    func focusIntentForNewWorkspaceMove(panel: any Panel) -> PanelFocusIntent {
        if panel is BrowserPanel {
            // Moving a browser tab into a standalone workspace should expose browser chrome,
            // even if web content was the last in-panel responder before the drag.
            return .browser(.addressBar)
        }
        return panel.preferredFocusIntentForActivation()
    }

    private func titleForDetachedWorkspace(
        explicitTitle: String?,
        workspace: Workspace,
        panelId: UUID,
        panel: any Panel
    ) -> String {
        let trimmedTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let fallbackTitle = workspace.panelTitle(panelId: panelId) ?? panel.displayTitle
        let trimmedFallbackTitle = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackTitle.isEmpty {
            return trimmedFallbackTitle
        }

        return String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
    }
}
