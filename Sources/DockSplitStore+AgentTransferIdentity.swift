import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Darwin

/// Cross-container surface transfer for the Dock.
///
/// Mirrors `Workspace.detachSurface`/`attachDetachedSurface` so a *live* panel
/// (rather than a copy) can move between the main split area and a Dock, or
/// between Docks, reusing the same `DetachedSurfaceTransfer`
/// currency the workspace-to-workspace move already uses. The Dock keeps its
/// own panel registry (`panels`/`surfaceIdToPanelId`), so these methods manage
/// that registry directly rather than going through the workspace pane tree.

extension DockSplitStore {
    static func dockAgentPIDProbeIndicatesExited(result: Int32, errnoCode: Int32) -> Bool {
        result != 0 && errnoCode == ESRCH
    }

    /// Computes the resume-cwd rescue value to carry out of the Dock. A nil
    /// preserved value means cwd tracking was intentionally suppressed.
    static func dockRestoredResumeSessionWorkingDirectory(
        preservedSessionDirectory: String?,
        detachedDirectory: String?,
        detachedDirectoryWasReadFromLiveForegroundProcess: Bool,
        agentProvenExited: Bool
    ) -> String? {
        guard !agentProvenExited else { return nil }
        guard preservedSessionDirectory != nil else { return nil }
        return detachedDirectoryWasReadFromLiveForegroundProcess
            ? detachedDirectory
            : preservedSessionDirectory
    }

    static func dockResumeBinding(
        preservedBinding: SurfaceResumeBindingSnapshot?,
        preservedSessionDirectory: String?,
        restoredResumeSessionWorkingDirectory: String?,
        detachedDirectoryWasReadFromLiveForegroundProcess: Bool,
        agentProvenExited: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        guard !agentProvenExited, let preservedBinding else { return nil }
        guard detachedDirectoryWasReadFromLiveForegroundProcess,
              let preservedSessionDirectory,
              let restoredResumeSessionWorkingDirectory else {
            return preservedBinding
        }
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: preservedBinding.kind ?? "",
            runtimeCwd: restoredResumeSessionWorkingDirectory,
            launchWorkingDirectory: preservedSessionDirectory
        )
        guard resolvedWorkingDirectory != preservedBinding.cwd else { return preservedBinding }
        return preservedBinding.retargetingWorkingDirectory(resolvedWorkingDirectory)
    }

    static func dockAgentPIDHasExited(_ pid: pid_t) -> Bool {
        errno = 0
        let result = Darwin.kill(pid, 0)
        return dockAgentPIDProbeIndicatesExited(result: result, errnoCode: errno)
    }
}
