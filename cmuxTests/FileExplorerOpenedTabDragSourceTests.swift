import AppKit
@testable import Bonsplit
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the open-from-explorer path behind cmux issue 12152: every explorer
/// entrypoint (double-click, Enter, search result, context menu, pane-hosted
/// explorer) converges on `Workspace.openFileSurfaces` with these arguments,
/// and the resulting tab must be a live pane-transfer source that every drop
/// destination resolves as the surface itself.
@MainActor
@Suite("File explorer opened tab drag source", .serialized)
struct FileExplorerOpenedTabDragSourceTests {
    @Test("A file opened from the explorer is a live surface for pane transfers")
    func openedFileTabResolvesAsLiveSurface() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let workspace = fixture.workspace
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-explorer-open-\(UUID().uuidString)")
                .appendingPathExtension("yml")
            try "services:\n  web:\n    image: nginx\n".write(to: fileURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let paneId = try #require(
                workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
            )
            let openedPanels = workspace.openFileSurfaces(
                inPane: paneId,
                filePaths: [fileURL.path],
                focus: true,
                reuseExisting: true,
                duplicateWhenFocused: true
            )
            let panel = try #require(openedPanels.first as? FilePreviewPanel)
            let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
            let pane = try #require(workspace.bonsplitController.internalController.paneState(for: paneId))
            let tab = try #require(pane.tabs.first { $0.id == tabId.uuid })
            #expect(pane.selectedTabId == tabId.uuid)
            #expect(tab.kind == SurfaceKind.filePreview.rawValue)

            // The strip drags this tab as a live Bonsplit surface. No synthetic
            // file-preview registration may shadow it, and every destination
            // must accept the surface transfer.
            let resolver = PaneTransferSourceResolver()
            let transfer = PaneDragTransfer(
                tabId: tabId.uuid,
                sourcePaneId: paneId.id,
                sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
            )
            #expect(resolver.registeredSource(id: tabId.uuid) == nil)
            #expect(resolver.source(for: transfer) == .surface)
            #expect(workspace.canPerformPortalPaneDrop(transfer, source: .surface))

            // The capability Bonsplit publishes when the drag session begins
            // resolves back to this tab through cmux's shared registry.
            let registry = fixture.appDelegate.tabDragTransferRegistry
            let registration = try #require(registry.register(TabDragTransfer(
                tab: Tab(from: tab),
                sourcePaneId: paneId
            )))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(
                "cmux.test.explorer-open-drag.\(UUID().uuidString)"
            ))
            pasteboard.clearContents()
            defer {
                registry.end(registration)
                pasteboard.clearContents()
            }
            #expect(registration.write(to: pasteboard))
            let resolved = try #require(resolver.transfer(from: pasteboard))
            #expect(resolved.tabId == tabId.uuid)
            #expect(resolver.source(for: resolved) == .surface)
        }
    }
}
