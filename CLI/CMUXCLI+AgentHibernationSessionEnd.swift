import Foundation

extension CMUXCLI {
    /// Asks the app whether this hook belongs to a pre-signaled hibernation
    /// generation. Unknown methods are treated as a negative answer so older
    /// app builds retain their existing cleanup behavior.
    func shouldPreserveClaudeSessionEndForHibernation(
        mappedSession: ClaudeHookSessionRecord?,
        parsedInput: ClaudeHookParsedInput,
        targetWorkspaceID: String,
        targetSurfaceID: String,
        client: SocketClient
    ) -> Bool {
        guard let sessionID = parsedInput.sessionId ?? mappedSession?.sessionId,
              let pid = mappedSession?.pid,
              let startSeconds = mappedSession?.pidStartSeconds,
              let startMicroseconds = mappedSession?.pidStartMicroseconds else {
            return false
        }
        let params: [String: Any] = [
            "workspace_id": targetWorkspaceID,
            "surface_id": targetSurfaceID,
            "session_id": sessionID,
            "pid": pid,
            "pid_start_seconds": startSeconds,
            "pid_start_microseconds": startMicroseconds,
        ]
        do {
            let result = try client.sendV2(
                method: "agent.hibernation.session_end",
                params: params,
                responseTimeout: 2
            )
            return result["preserve"] as? Bool == true
        } catch {
            return false
        }
    }
}
