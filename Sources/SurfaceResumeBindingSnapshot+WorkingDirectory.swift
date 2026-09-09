import CMUXAgentLaunch
import Foundation

extension SurfaceResumeBindingSnapshot {
    func retargetingWorkingDirectory(_ workingDirectory: String?) -> SurfaceResumeBindingSnapshot {
        guard isAgentHookBinding else { return self }
        if case .unavailable = restoreWorkingDirectorySelection {
            return self
        }
        let normalizedCwd = Self.normalized(workingDirectory)
        var retargeted = self
        let normalizedKind = Self.normalized(kind)
        retargeted.command = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: command,
            previousWorkingDirectory: cwd,
            workingDirectory: normalizedCwd
        )
        retargeted.cwd = normalizedCwd
        if var launchCommand = retargeted.launchCommand {
            launchCommand.workingDirectory = normalizedCwd
            retargeted.launchCommand = launchCommand
        }
        // An id-keyed agent's live cwd is authoritative for the refreshed
        // binding. Directory-keyed agents must retain their launch namespace.
        if AgentResumeWorkingDirectory().cwdNamespacing(forKind: normalizedKind ?? "") == .cwdInFile {
            retargeted.restoreWorkingDirectorySelection = .exact(normalizedCwd)
        }
        return retargeted
    }
}
