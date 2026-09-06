import Foundation

/// Resolves a remote PTY failure into a presentation category without owning
/// localized copy or app lifecycle state.
public struct RemotePTYErrorPresentation: Equatable, Sendable {
    /// The stable categories understood by remote PTY callers.
    public enum Kind: Equatable, Sendable {
        /// The remote daemon does not support the required PTY capability.
        case capabilityMissing
        /// The requested persistent PTY session is no longer running.
        case sessionNotFound
        /// The daemon temporarily cannot accept more PTY input.
        case inputQueueFull
        /// The remote connection or daemon is not currently usable.
        case connectionInactive
        /// The daemon has not become ready yet.
        case daemonNotReady
        /// A session-list response omitted its workspace identifier.
        case missingWorkspaceID
        /// A session-list response omitted its session identifier.
        case missingSessionID
        /// The daemon did not answer before the operation deadline.
        case timeout
        /// No known presentation category matched the failure.
        case generic
    }

    /// The category selected for the supplied failure.
    public let kind: Kind

    /// Resolves a message and optional structured code into a category.
    ///
    /// Legacy marker matching is retained for older daemon/app pairs. A
    /// structured code is consulted only after those compatibility markers.
    ///
    /// - Parameters:
    ///   - message: The daemon or transport diagnostic.
    ///   - code: The stable wire code, when one is available.
    public init(message: String, code: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            kind = .generic
            return
        }
        let lowered = trimmed.lowercased()

        if lowered.contains("missing required capability") ||
            lowered.contains("missing required capabilities") ||
            lowered.contains("does not support persistent ssh pty sessions") ||
            lowered.contains("pty.session") ||
            lowered.contains("method_not_found") ||
            lowered.contains("unrecognized_method") {
            kind = .capabilityMissing
            return
        }
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
            (lowered.contains("persistent pty session") && lowered.contains("not running")) {
            kind = .sessionNotFound
            return
        }
        if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
            kind = .inputQueueFull
            return
        }
        if lowered.contains("remote connection is not active") {
            kind = .connectionInactive
            return
        }
        if lowered.contains("remote daemon is not ready") ||
            lowered.contains("remote daemon tunnel is not ready") {
            kind = .daemonNotReady
            return
        }
        if lowered.contains("missing workspace_id in ssh pty session list response") {
            kind = .missingWorkspaceID
            return
        }
        if lowered.contains("missing session_id in ssh pty session list response") {
            kind = .missingSessionID
            return
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            kind = .timeout
            return
        }

        guard let code = RemotePTYErrorCode.normalized(code) else {
            kind = .generic
            return
        }
        switch code {
        case RemotePTYErrorCode.capabilityMissing.rawValue:
            kind = .capabilityMissing
        case RemotePTYErrorCode.sessionNotFound.rawValue:
            kind = .sessionNotFound
        case RemotePTYErrorCode.inputQueueFull.rawValue:
            kind = .inputQueueFull
        case RemotePTYErrorCode.connectionInactive.rawValue:
            kind = .connectionInactive
        case RemotePTYErrorCode.timeout.rawValue:
            kind = .timeout
        default:
            kind = .generic
        }
    }

    /// Resolves an error using its localized diagnostic and structured code.
    ///
    /// - Parameter error: The remote PTY failure to classify.
    public init(error: any Error) {
        self.init(
            message: error.localizedDescription,
            code: RemotePTYErrorCode.code(for: error)
        )
    }
}
