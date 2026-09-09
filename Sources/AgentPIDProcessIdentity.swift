import CmuxAgentLifecycle
import Darwin

typealias AgentPIDProcessIdentity =
    CmuxAgentLifecycle.AgentProcessGeneration

extension AgentPIDProcessIdentity {
    /// Resolves the exact live generation for a positive agent-turn PID.
    init?(agentTurnPID pid: Int?) {
        guard let pid,
              pid > 0,
              pid <= Int(Int32.max),
              let generation = AgentPIDProcessIdentity(pid: pid_t(pid)) else {
            return nil
        }
        self = generation
    }

    /// Observes whether this exact process generation is still live.
    var liveness: AgentTurnProcessLiveness {
        AgentTurnProcessLiveness.observe(
            pid: Int(pid),
            expectedStartSeconds: startSeconds,
            expectedStartMicroseconds: startMicroseconds
        )
    }

    /// Reads a live process's birth timestamp, distinguishing PID reuse.
    ///
    /// `sysctl` can read privileged process rows that `proc_pidinfo` rejects.
    /// Zombies are rejected explicitly so a readable identity always means the
    /// process can still perform work.
    init?(pid: pid_t) {
        guard let entry = Self.processTableEntry(pid: pid),
              !entry.hasExited else {
            return nil
        }
        self.init(
            pid: pid,
            startSeconds: entry.startSeconds,
            startMicroseconds: entry.startMicroseconds
        )
    }

    /// Whether the process exited without yet being reaped.
    static func hasExitedWithoutReaping(pid: pid_t) -> Bool {
        processTableEntry(pid: pid)?.hasExited ?? false
    }

    /// Reads identity and ancestry from one kernel snapshot so callers do not
    /// accidentally combine a reused PID with metadata from different process
    /// generations.
    static func processSnapshot(
        pid: pid_t
    ) -> (identity: AgentPIDProcessIdentity, parentPID: pid_t)? {
        guard let entry = processTableEntry(pid: pid), !entry.hasExited else {
            return nil
        }
        return (
            identity: AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: entry.startSeconds,
                startMicroseconds: entry.startMicroseconds
            ),
            parentPID: entry.parentPID
        )
    }

    private static func processTableEntry(
        pid: pid_t
    ) -> (
        startSeconds: Int64,
        startMicroseconds: Int64,
        parentPID: pid_t,
        hasExited: Bool
    )? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else {
            return nil
        }
        let started = info.kp_proc.p_un.__p_starttime
        return (
            Int64(started.tv_sec),
            Int64(started.tv_usec),
            pid_t(info.kp_eproc.e_ppid),
            info.kp_proc.p_stat == Int8(SZOMB)
        )
    }
}
