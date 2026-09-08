import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ghostty types a restored agent's `cmux restore` selector as soon as the PTY
/// exists. A slow login shell can discard that typeahead while it initializes,
/// leaving the pane at an empty prompt (https://github.com/manaflow-ai/cmux/issues/5473).
/// The lifecycle coordinator retains the input so the owner can replay it once.
@MainActor
@Suite("Restored startup input resend")
struct RestoredStartupInputResendTests {
    private let selector = " cmux restore antigravity 6e8458c7-7970-41e0-8d3e-00beda48097b\n"

    private func awaitingCoordinator(panelId: UUID) -> RestoredAgentLifecycleCoordinator {
        let coordinator = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        coordinator.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: false,
            willRunStartupCommand: false,
            willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        coordinator.registerStartupInput(selector, panelId: panelId)
        return coordinator
    }

    @Test("Replays the retained input once while the launch is still waiting at an idle prompt")
    func replaysOnceWhilePromptStaysIdle() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)

        #expect(coordinator.awaitsStartupInput(panelId: panelId))
        #expect(coordinator.armStartupInputResend(panelId: panelId))
        // A second idle-prompt report must not arm a second timer.
        #expect(!coordinator.armStartupInputResend(panelId: panelId))

        #expect(
            coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == selector
        )
        // Only one replay is ever handed out.
        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
    }

    @Test("A prompt-then-command sequence that reached the command phase is not replayed")
    func doesNotReplayOnceTheCommandStarted() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)
        #expect(coordinator.armStartupInputResend(panelId: panelId))

        // Shell integration reported the command running before the grace period elapsed.
        coordinator.setResumeState(.autoResumeCommandRunning, panelId: panelId)
        coordinator.clearStartupInput(panelId: panelId)

        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
    }

    @Test("A shell that is no longer idle when the grace period ends is left alone")
    func doesNotReplayIntoARunningCommand() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)
        #expect(coordinator.armStartupInputResend(panelId: panelId))

        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .commandRunning) == nil)
        // The input stays retained for a later idle prompt.
        #expect(coordinator.awaitsStartupInput(panelId: panelId))
    }

    @Test("Manual and unrestored launches never arm a replay")
    func onlyAwaitingLaunchesArm() {
        let panelId = UUID()
        let coordinator = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        coordinator.registerStartupInput(selector, panelId: panelId)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
        #expect(!coordinator.armStartupInputResend(panelId: panelId))

        coordinator.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeWorkingDirectory: nil
        )
        #expect(!coordinator.armStartupInputResend(panelId: panelId))
        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
    }

    @Test("Tearing down the restore forgets the retained input")
    func clearSessionRestoreForgetsInput() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)
        coordinator.clearSessionRestore(panelId: panelId)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
    }

    @Test("A workspace replays the lost selector after its shell settles at an idle prompt")
    func workspaceReplaysAfterIdlePrompt() async throws {
        let previousGrace = Workspace.restoredStartupInputResendGrace
        Workspace.restoredStartupInputResendGrace = 0.05
        defer { Workspace.restoredStartupInputResendGrace = previousGrace }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        workspace.restoredAgentLifecycle.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: false,
            willRunStartupCommand: false,
            willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        workspace.restoredAgentLifecycle.registerStartupInput(selector, panelId: panelId)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        // The grace period keeps a prompt-then-command sequence from double-typing.
        #expect(workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))

        try await Task.sleep(for: .milliseconds(400))
        #expect(!workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test("A workspace whose shell ran the typed selector keeps nothing to replay")
    func workspaceClearsInputOnceCommandRuns() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        workspace.restoredAgentLifecycle.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: false,
            willRunStartupCommand: false,
            willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        workspace.restoredAgentLifecycle.registerStartupInput(selector, panelId: panelId)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        #expect(!workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(!workspace.restoredAgentLifecycle.armStartupInputResend(panelId: panelId))
    }
}
