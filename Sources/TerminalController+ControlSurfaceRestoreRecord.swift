import Foundation
import CMUXAgentLaunch
import CmuxControlSocket

extension TerminalController {
    func controlSurfaceRestoreRecord(
        target: ControlSurfaceResumeTarget,
        binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceRestoreRecord? {
        // Structured fields remain untouched; only the explicit legacy fallback
        // receives restore-time provider refreshes that older records depended on.
        let compatibilityBinding = binding.map {
            Workspace.makeSessionRestorePolicyService()
                .bindingForCompatibilityShellRestore($0)
        }
        // A persistent-SSH agent-hook binding without a stored cwd trust
        // decision is legacy/unscoped state.  It may still contain a local
        // launch recipe, so never let the control-surface fallback turn that
        // missing policy into an executable restore record.  The authenticated
        // hook refresh path can replace this binding with an explicit selection.
        let isUnscopedRemoteAgentHook = binding?.isAgentHookBinding == true &&
            binding?.launchFlavor.remoteContext != nil &&
            binding?.restoreWorkingDirectorySelection == nil
        guard !isUnscopedRemoteAgentHook else { return nil }
        guard binding?.restoreWorkingDirectorySelection?.permitsResume != false else {
            return nil
        }
        // A hook can replace the live binding after this surface was restored,
        // while the restore-time agent snapshot still names the previous
        // conversation. Reuse the session-restore identity gate so the record
        // returned to the CLI always agrees with the binding that generated its
        // typed `cmux restore`/`cmux fork` selector.
        let restoredAgent = target.restorableAgent
        let compatibleAgent: (
            snapshot: SessionRestorableAgentSnapshot,
            source: String,
            restoredWorkingDirectory: String?
        )?
        if binding == nil || binding?.isAgentHookBinding == true {
            if let restoredAgent = Workspace.restorableAgentForSessionRestore(
                restoredAgent,
                resumeBinding: binding
            ) {
                compatibleAgent = (
                    restoredAgent,
                    "session-snapshot",
                    target.restoredResumeWorkingDirectory
                )
            } else {
                compatibleAgent = nil
            }
        } else {
            compatibleAgent = nil
        }
        if let compatibleAgent {
            return controlSurfaceAgentContinuationRecord(
                agent: compatibleAgent.snapshot,
                source: compatibleAgent.source,
                restoredWorkingDirectory: compatibleAgent.restoredWorkingDirectory,
                binding: binding,
                compatibilityBinding: compatibilityBinding
            )
        }
        guard binding?.isAgentHookBinding != true ||
                target.restorableAgent?.restoreWorkingDirectorySelection == nil else {
            return nil
        }
        guard let binding else { return nil }
        return controlSurfaceBindingContinuationRecord(
            target: target,
            binding: binding,
            compatibilityBinding: compatibilityBinding,
            restoredAgentExists: restoredAgent != nil && binding.isAgentHookBinding
        )
    }

}
