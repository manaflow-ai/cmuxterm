import Foundation

/// Foreground-process evidence that a restored or hook-published agent is
/// still the command running in its pane.
///
/// Pi-compatible TUIs emit OSC 133 prompt and command marks while the agent
/// keeps running, so cmux's shell-activity state flips between idle and busy
/// on every turn. A flip alone cannot prove that the agent exited or was
/// replaced (#12084); the process in the pane's foreground can. This covers
/// the window before the agent's session-start hook has registered its PID
/// with cmux, when neither the runtime PID table nor the live agent index can
/// vouch for the session yet.
enum RestoredAgentForegroundProcess {
    /// Whether the pane's foreground process is `agent`'s own process.
    ///
    /// The identity validator applies the same executable, launch-kind, and
    /// session checks the live agent index uses for hook-recorded PIDs, so a
    /// shell (or an unrelated command) never counts as the agent. Pi overwrites
    /// its argv with a bare title, so a foreground process that shows no
    /// session identity is vouched for only while the session has registered
    /// no process of its own, or when it is that registered process; once a
    /// different process sits in the pane it must name this session in argv.
    /// A contradicting session identity always rejects.
    ///
    /// - Parameter recordedProcessID: the hook-registered PID for `agent`'s
    ///   session on this pane, if any.
    static func matches(
        _ agent: SessionRestorableAgentSnapshot,
        foregroundProcessID: Int?,
        recordedProcessID: Int? = nil,
        processArguments: (Int) -> CmuxTopProcessArguments? =
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for:),
        validator: CachedAgentProcessIdentityValidator = CachedAgentProcessIdentityValidator()
    ) -> Bool {
        guard let foregroundProcessID,
              foregroundProcessID > 0,
              foregroundProcessID <= Int(Int32.max),
              let process = processArguments(foregroundProcessID) else {
            return false
        }
        let vouchesForMissingIdentity = recordedProcessID == nil || recordedProcessID == foregroundProcessID
        return validator.currentProcess(
            process,
            matches: agent,
            hermesSessionValidation: vouchesForMissingIdentity ? .paneForegroundProcess : .cachedSnapshot
        )
    }
}
