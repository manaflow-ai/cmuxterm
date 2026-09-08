import AppKit
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sticky prompt header", .serialized)
struct StickyPromptHeaderTests {
    @Test func overlayPassesPointerEventsToTerminal() {
        let overlay = StickyPromptHeaderOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        overlay.setEntry(TerminalPromptHistoryEntry(preview: "A prompt", anchor: nil))

        #expect(!overlay.isHidden)
        #expect(overlay.hitTest(NSPoint(x: 20, y: 14)) == nil)
        #expect(overlay.accessibilityLabel() == "A prompt")

        overlay.setEntry(nil)
        #expect(overlay.isHidden)
        #expect(overlay.currentEntry == nil)
        #expect(overlay.accessibilityLabel() == nil)
    }

    @Test func submissionPublishesOneEventWithSurfaceAndPosition() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let workspaceID = UUID()
        let surfaceID = UUID()
        CmuxEventBus.shared.publishWorkspacePromptSubmitted(
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            message: "A prompt",
            preview: "A prompt",
            promptAnchor: TerminalPromptAnchor(row: 42, rowSpaceRevision: 7)
        )

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event["surface_id"] as? String == surfaceID.uuidString)
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(payload["scrollback_row"] as? Int == 42)
        #expect(payload["scrollback_row_space_revision"] as? UInt64 == 7)
        #expect(payload["message"] is NSNull)
    }

    @Test func unknownSurfaceDoesNotFallBackToFocusedPane() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let outcome = try #require(manager.handlePromptSubmit(
            workspaceId: workspace.id,
            message: "Do not attribute this to the focused terminal",
            surfaceId: UUID(),
            iMessageModeEnabled: false
        ))

        #expect(outcome.messageRecorded)
        let events = CmuxEventBus.shared.retainedSnapshot()
            .filter { $0["name"] as? String == "workspace.prompt.submitted" }
        #expect(events.count == 1)
        let payload = try #require(events.first?["payload"] as? [String: Any])
        #expect(payload["surface_id"] is NSNull)
        #expect(payload["scrollback_row"] is NSNull)
    }

    @Test func knownSurfaceSubmissionPublishesExactlyOnce() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        let terminal = try #require(workspace.focusedTerminalPanel)
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        _ = manager.handlePromptSubmit(
            workspaceId: workspace.id,
            message: "A real submitted turn",
            surfaceId: terminal.id,
            iMessageModeEnabled: false
        )

        let events = CmuxEventBus.shared.retainedSnapshot()
            .filter { $0["name"] as? String == "workspace.prompt.submitted" }
        #expect(events.count == 1)
        #expect(events.first?["surface_id"] as? String == terminal.id.uuidString)
    }

    @Test func bindingDifferentSurfaceClearsPromptHistory() throws {
        let manager = TabManager()
        let first = try #require(manager.tabs.first?.focusedTerminalPanel)
        let secondWorkspace = manager.addWorkspace(select: false, placementOverride: .end)
        let second = try #require(secondWorkspace.focusedTerminalPanel)
        let controller = StickyPromptHeaderController()
        _ = controller.record("first pane", surface: first.surface)
        #expect(controller.hasPrompt)
        controller.bind(first.surface)
        #expect(controller.hasPrompt)

        controller.bind(second.surface)
        #expect(!controller.hasPrompt)
        let geometry = NotificationScrollRestoreGeometry(
            scrollbar: GhosttyScrollbar(total: 30, offset: 0, len: 30),
            rowSpaceRevision: 0
        )
        #expect(controller.selectedEntry(geometry: geometry) == nil)
    }
}
