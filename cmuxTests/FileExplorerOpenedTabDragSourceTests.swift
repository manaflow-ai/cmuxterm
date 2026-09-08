import AppKit
@testable import Bonsplit
import CmuxWorkspaces
import Foundation
import SwiftUI
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

    @Test("The strip arms a native drag for the explorer-opened tab on its first laid-out press")
    func openedFileTabArmsOnFirstLaidOutPress() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let workspace = fixture.workspace
            let controller = workspace.bonsplitController
            controller.tabShortcutHintsEnabled = false
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-explorer-open-\(UUID().uuidString)")
                .appendingPathExtension("yml")
            try "services:\n  web:\n    image: nginx\n".write(to: fileURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            // Host the workspace's real tab strip: the same BonsplitView the app
            // renders, driven by the same controller the explorer mutates.
            let hostingView = NSHostingView(
                rootView: BonsplitView(controller: controller) { _, _ in Color.clear }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView)
            hostingView.frame = contentView.bounds
            hostingView.autoresizingMask = [.width, .height]
            contentView.addSubview(hostingView)
            window.makeKeyAndOrderFront(nil)
            Self.settle(window, hostingView)

            let paneId = try #require(controller.focusedPaneId ?? controller.allPaneIds.first)
            let openedPanels = workspace.openFileSurfaces(
                inPane: paneId,
                filePaths: [fileURL.path],
                focus: true,
                reuseExisting: true,
                duplicateWhenFocused: true
            )
            let panel = try #require(openedPanels.first as? FilePreviewPanel)
            let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
            Self.settle(window, hostingView)

            let strip = try #require(
                Self.descendants(ofType: TabBarDragAndHoverView.TabBarBackgroundNSView.self, in: hostingView).first
            )
            let frame = try #require(strip.geometryRegistry?.frame(for: tabId.uuid, in: strip))
            let pressPoint = NSPoint(x: frame.midX, y: frame.midY)
            // A press on the laid-out tab is a tab press for the strip
            // background, so minimal mode never turns it into a window drag.
            #expect(strip.containsBonsplitTabItemHit(localPoint: pressPoint))

            var armedTabId: UUID?
            strip.onBeginTabDrag = { armed, _, _, _, _ in
                armedTabId = armed
                return true
            }
            let windowPoint = strip.convert(pressPoint, to: nil)
            let mouseDown = try Self.mouseEvent(.leftMouseDown, window: window, at: windowPoint)
            let mouseDragged = try Self.mouseEvent(
                .leftMouseDragged,
                window: window,
                at: NSPoint(x: windowPoint.x + 12, y: windowPoint.y)
            )
            _ = strip.handleTabDragEvent(mouseDown)
            _ = strip.handleTabDragEvent(mouseDragged)
            #expect(armedTabId == tabId.uuid)
        }
    }

    private static func settle(_ window: NSWindow, _ hostingView: NSView, passes: Int = 8) {
        for _ in 0..<passes {
            window.contentView?.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.02))
        }
    }

    private static func descendants<T: NSView>(ofType type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(ofType: type, in: subview))
        }
        return matches
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        window: NSWindow,
        at windowPoint: NSPoint
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
