import Bonsplit
import Foundation

extension Workspace {
    /// Opens a heterogeneous file batch as tabs in one pane.
    ///
    /// Focused batches apply the new-tab zoom transaction once, even when the
    /// batch contains many files. Reused tabs do not count as creation, so a
    /// batch whose creation attempts all fail restores the previous zoom.
    @discardableResult
    func openFileSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [any Panel] {
        guard !isRetiredFromOwningTabManager else { return [] }
        guard !filePaths.isEmpty else { return [] }
        let shouldFocusNewTabs = focus ?? (bonsplitController.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [any Panel] = []
        let panelIdsBeforeOpen = Set(panels.keys)
        var existingMarkdownPanels: [String: MarkdownPanel] = reuseExisting
            ? panels.values.reduce(into: [:]) { result, panel in
                guard let markdownPanel = panel as? MarkdownPanel else { return }
                let canonical = (markdownPanel.filePath as NSString).resolvingSymlinksInPath
                if result[canonical] == nil {
                    result[canonical] = markdownPanel
                }
            }
            : [:]
        var existingPreviewPanels: [String: FilePreviewPanel] = reuseExisting
            ? panels.values.reduce(into: [:]) { result, panel in
                guard let previewPanel = panel as? FilePreviewPanel else { return }
                let canonical = (previewPanel.filePath as NSString).resolvingSymlinksInPath
                if result[canonical] == nil {
                    result[canonical] = previewPanel
                }
            }
            : [:]
        let willAttemptCreation = filePaths.contains { filePath in
            guard reuseExisting else { return true }
            let pathExtension = (filePath as NSString).pathExtension.lowercased()
            if pathExtension == "xcodeproj" || pathExtension == "xcworkspace" {
                return true
            }
            let canonical = (filePath as NSString).resolvingSymlinksInPath
            if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
                return existingMarkdownPanels[canonical] == nil
            }
            return existingPreviewPanels[canonical] == nil
        }
        defer {
            // Shared across every focused open entrypoint (sidebar click,
            // sidebar drag-drop, CLI/socket open, workspace actions): when
            // the right sidebar owns keyboard focus, hand it to the opened
            // panel so the find/shortcut router targets the document. A
            // freshly created panel's view mounts a runloop turn later and
            // cannot take first responder during activation, so this happens
            // at the coordinator level. No-op when the sidebar does not own
            // focus.
            if shouldFocusNewTabs, let firstPanel = openedPanels.first {
                handKeyboardFocusFromRightSidebarAfterFileOpen(to: firstPanel)
            }
        }

        _ = withNewTabZoomPolicy(
            inPane: paneId,
            applyPolicy: shouldFocusNewTabs && willAttemptCreation
        ) { () -> Bool? in
            for filePath in filePaths {
                let panel: (any Panel)?
                let pathExtension = (filePath as NSString).pathExtension.lowercased()
                if pathExtension == "xcodeproj" || pathExtension == "xcworkspace" {
                    panel = newProjectSurface(
                        inPane: paneId,
                        projectPath: filePath,
                        focus: shouldFocusNewTabs,
                        targetIndex: nextIndex
                    )
                } else if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
                    if reuseExisting {
                        let canonical = (filePath as NSString).resolvingSymlinksInPath
                        if let existingPanel = existingMarkdownPanels[canonical] {
                            if shouldFocusNewTabs {
                                focusPanel(existingPanel.id)
                            }
                            panel = existingPanel
                        } else {
                            let newPanel = newMarkdownSurface(
                                inPane: paneId,
                                filePath: filePath,
                                focus: shouldFocusNewTabs,
                                targetIndex: nextIndex
                            )
                            if let newPanel {
                                existingMarkdownPanels[canonical] = newPanel
                            }
                            panel = newPanel
                        }
                    } else {
                        panel = newMarkdownSurface(
                            inPane: paneId,
                            filePath: filePath,
                            focus: shouldFocusNewTabs,
                            targetIndex: nextIndex
                        )
                    }
                } else if reuseExisting {
                    let canonical = (filePath as NSString).resolvingSymlinksInPath
                    if let existingPanel = existingPreviewPanels[canonical] {
                        if shouldFocusNewTabs {
                            focusPanel(existingPanel.id)
                        }
                        panel = existingPanel
                    } else {
                        let newPanel = newFilePreviewSurface(
                            inPane: paneId,
                            filePath: filePath,
                            focus: shouldFocusNewTabs,
                            targetIndex: nextIndex
                        )
                        if let newPanel {
                            existingPreviewPanels[canonical] = newPanel
                        }
                        panel = newPanel
                    }
                } else {
                    panel = newFilePreviewSurface(
                        inPane: paneId,
                        filePath: filePath,
                        focus: shouldFocusNewTabs,
                        targetIndex: nextIndex
                    )
                }

                if let panel {
                    openedPanels.append(panel)
                    if let index = nextIndex {
                        nextIndex = index + 1
                    }
                }
            }

            let createdPanel = openedPanels.contains {
                !panelIdsBeforeOpen.contains($0.id)
            }
            return createdPanel ? true : nil
        }

        return openedPanels
    }

    /// Opens a file-preview batch as tabs in one pane with one zoom transaction.
    @discardableResult
    func openFilePreviewSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [FilePreviewPanel] {
        guard !isRetiredFromOwningTabManager else { return [] }
        guard !filePaths.isEmpty else { return [] }
        let shouldFocusNewTabs = focus ?? (bonsplitController.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [FilePreviewPanel] = []
        let panelIdsBeforeOpen = Set(panels.keys)
        var existingPreviewPanels: [String: FilePreviewPanel] = reuseExisting
            ? panels.values.reduce(into: [:]) { result, panel in
                guard let previewPanel = panel as? FilePreviewPanel else { return }
                let canonical = (previewPanel.filePath as NSString).resolvingSymlinksInPath
                if result[canonical] == nil {
                    result[canonical] = previewPanel
                }
            }
            : [:]
        let willAttemptCreation = filePaths.contains { filePath in
            !reuseExisting || existingPreviewPanels[
                (filePath as NSString).resolvingSymlinksInPath
            ] == nil
        }

        _ = withNewTabZoomPolicy(
            inPane: paneId,
            applyPolicy: shouldFocusNewTabs && willAttemptCreation
        ) { () -> Bool? in
            for filePath in filePaths {
                let panel: FilePreviewPanel?
                if reuseExisting {
                    let canonical = (filePath as NSString).resolvingSymlinksInPath
                    if let existingPanel = existingPreviewPanels[canonical] {
                        if shouldFocusNewTabs {
                            focusPanel(existingPanel.id)
                        }
                        panel = existingPanel
                    } else {
                        let newPanel = newFilePreviewSurface(
                            inPane: paneId,
                            filePath: filePath,
                            focus: shouldFocusNewTabs,
                            targetIndex: nextIndex
                        )
                        if let newPanel {
                            existingPreviewPanels[canonical] = newPanel
                        }
                        panel = newPanel
                    }
                } else {
                    panel = newFilePreviewSurface(
                        inPane: paneId,
                        filePath: filePath,
                        focus: shouldFocusNewTabs,
                        targetIndex: nextIndex
                    )
                }

                if let panel {
                    openedPanels.append(panel)
                    if let index = nextIndex {
                        nextIndex = index + 1
                    }
                }
            }

            let createdPanel = openedPanels.contains {
                !panelIdsBeforeOpen.contains($0.id)
            }
            return createdPanel ? true : nil
        }

        return openedPanels
    }
}
