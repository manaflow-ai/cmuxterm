import CmuxFoundation

extension TerminalController {
    /// Returns the machine-readable code placed on v2 remote-PTY failures.
    nonisolated func v2RemotePTYErrorCode(_ error: any Error) -> String {
        RemotePTYErrorCode.code(for: error)
    }

    /// Resolves the app-bundle human message for a remote-PTY failure.
    nonisolated func v2RemotePTYUserFacingErrorMessage(_ error: any Error) -> String {
        v2RemotePTYUserFacingErrorMessage(
            error.localizedDescription,
            code: v2RemotePTYErrorCode(error)
        )
    }

    /// Maps legacy remote-PTY text for older daemon/app pairs and display.
    nonisolated func v2RemotePTYUserFacingErrorMessage(_ message: String) -> String {
        v2RemotePTYUserFacingErrorMessage(message, code: nil)
    }

    private nonisolated func v2RemotePTYUserFacingErrorMessage(
        _ message: String,
        code: String?
    ) -> String {
        switch RemotePTYErrorPresentation(message: message, code: code).kind {
        case .capabilityMissing:
            return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        case .sessionNotFound:
            return "persistent SSH PTY session is no longer running"
        case .inputQueueFull:
            return "remote PTY input is temporarily backed up"
        case .connectionInactive:
            return "remote connection is not active"
        case .daemonNotReady:
            return "remote daemon is not ready"
        case .missingWorkspaceID:
            return "missing workspace_id in SSH PTY session list response"
        case .missingSessionID:
            return "missing session_id in SSH PTY session list response"
        case .timeout:
            return "remote daemon did not respond in time"
        case .generic:
            return "remote PTY operation failed"
        }
    }
}
