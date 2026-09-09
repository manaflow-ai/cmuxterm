import Darwin
import Foundation
import Testing
import Bonsplit
import CmuxCore
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationTests {
    @MainActor
    @Test
    func testDirectFocusOnHibernatedTerminalPreparesResumeWithoutHiddenFocus() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-direct-focus-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        panel.focus()

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testExplicitInputToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-explicit-input-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendInputResult("pwd\r")

        expectEqual(result, .queued)
        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testMovedHibernatedTerminalResumesThroughDestinationWorkspace() throws {
        let source = Workspace()
        let panelId = try #require(source.focusedPanelId)
        let panel = try #require(source.panels[panelId] as? TerminalPanel)
        let detached = try #require(source.detachSurface(panelId: panelId))

        let destination = Workspace()
        let destinationPaneId = try #require(destination.bonsplitController.focusedPaneId)
        expectEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPaneId, focus: false),
            panelId
        )

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-moved-explicit-input-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        destination.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        let result = panel.sendInputResult("pwd\r")

        expectEqual(result, .queued)
        expectFalse(panel.isAgentHibernated)
        expectNil(source.restoredAgentResumeStatesByPanelId[panelId])
        expectEqual(destination.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testExplicitNamedKeyToHibernatedTerminalQueuesAndPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-explicit-key-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        let result = panel.sendNamedKeyResult("enter")

        expectEqual(result, .queued)
        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testResumePreparationWithoutStartupInputStillLeavesHibernation() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("manual-agent"),
            sessionId: "manual-agent-session",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: nil
        )

        panel.enterAgentHibernation(
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        let preparation = panel.prepareAgentHibernationResume()

        expectEqual(preparation, .resumed(queuedStartupInput: false))
        expectFalse(panel.isAgentHibernated)
        expectFalse(panel.surface.debugInitialInputMetadata().hasInitialInput)
    }

}
