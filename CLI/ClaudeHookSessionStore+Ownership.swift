import Foundation
import Darwin

extension ClaudeHookSessionStore {
    func processStartIdentity(pid: Int) -> (seconds: Int64, microseconds: Int64)? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        return (
            seconds: Int64(info.pbi_start_tvsec),
            microseconds: Int64(info.pbi_start_tvusec)
        )
    }

    func authoritativeSessionStartProcessIsNewer(
        _ incomingPID: Int?,
        than activeRecord: ClaudeHookSessionRecord
    ) -> Bool {
        guard let incomingPID,
              let incomingIdentity = processStartIdentity(pid: incomingPID) else {
            return false
        }
        if let seconds = activeRecord.pidStartSeconds,
           let microseconds = activeRecord.pidStartMicroseconds {
            return (incomingIdentity.seconds, incomingIdentity.microseconds) > (seconds, microseconds)
        }
        guard let activePID = activeRecord.pid,
              activePID != incomingPID else {
            return false
        }
        return !Self.processExists(activePID)
    }

    /// Returns true when an event belongs to the workspace's active Claude session.
    /// It fails open when the event cannot identify a session/workspace, when no
    /// active session is registered yet, or when either side lacks a turnId so
    /// multi-turn continuations can proceed after Stop clears the active turn.
    func isCurrent(
        sessionId: String?,
        workspaceId: String,
        surfaceId: String? = nil,
        turnId: String? = nil
    ) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return true
        }
        return try withLockedState { state in
            // The pane's own active boundary decides first: a hook is stale when a
            // DIFFERENT session was promoted in the SAME surface (post-/clear or
            // replaced-session races in one pane). This stays true even after a
            // sibling pane — e.g. a forked conversation in a split — later takes
            // the single workspace-active slot.
            // https://github.com/manaflow-ai/cmux/issues/5908
            if let normalizedSurfaceId = normalizeOptional(surfaceId),
               let surfaceActive = state.activeSessionsBySurface[normalizedSurfaceId] {
                guard surfaceActive.sessionId == normalizedSessionId else {
                    return false
                }
                guard let activeTurnId = normalizeOptional(surfaceActive.turnId),
                      let normalizedTurnId = normalizeOptional(turnId) else {
                    return true
                }
                return activeTurnId == normalizedTurnId
            }
            guard let active = state.activeSessionsByWorkspace[normalizedWorkspace] else {
                return true
            }
            guard active.sessionId == normalizedSessionId else {
                // Legacy fallback for stores written before per-surface tracking:
                // a different active session only makes this hook stale when that
                // session lives in the SAME surface; concurrent sessions in
                // sibling panes stay current for their own surface.
                guard let normalizedSurfaceId = normalizeOptional(surfaceId),
                      let activeRecord = state.sessions[active.sessionId],
                      let activeSurfaceId = normalizeOptional(activeRecord.surfaceId) else {
                    // Cross-surface protection needs both surfaces; when the caller
                    // omits surfaceId or the active session's record is gone/surface-
                    // less, fall back to the stricter workspace-scoped staleness.
                    return false
                }
                return activeSurfaceId != normalizedSurfaceId
            }
            guard let activeTurnId = normalizeOptional(active.turnId),
                  let normalizedTurnId = normalizeOptional(turnId) else {
                return true
            }
            return activeTurnId == normalizedTurnId
        }
    }

    func canReplaceActiveSession(
        sessionId: String?,
        workspaceId: String,
        surfaceId: String? = nil
    ) throws -> Bool {
        guard let normalizedSessionId = normalizeOptional(sessionId),
              let normalizedWorkspace = normalizeOptional(workspaceId) else {
            return false
        }
        return try withLockedState { state in
            // Replacement is pane-scoped like staleness: a stopped session in
            // THIS surface allows its own pane to start a new session even when
            // another pane currently holds the workspace-active slot.
            // https://github.com/manaflow-ai/cmux/issues/5908
            if let normalizedSurfaceId = normalizeOptional(surfaceId),
               let surfaceActive = state.activeSessionsBySurface[normalizedSurfaceId] {
                guard surfaceActive.sessionId != normalizedSessionId else {
                    return false
                }
                return surfaceActive.allowsNewSessionReplacement == true
            }
            guard let active = state.activeSessionsByWorkspace[normalizedWorkspace],
                  active.sessionId != normalizedSessionId else {
                return false
            }
            return active.allowsNewSessionReplacement == true
        }
    }
}
