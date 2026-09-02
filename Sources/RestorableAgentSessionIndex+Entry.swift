import Foundation

extension RestorableAgentSessionIndex {
    struct Entry: Sendable {
        let snapshot: SessionRestorableAgentSnapshot
        let lifecycle: AgentHibernationLifecycleState?
        /// Latest accepted hook event time for live-idle reconciliation.
        let runtimeStatusEventTime: TimeInterval?
        let updatedAt: TimeInterval
        /// Unlike an empty process ID set, this distinguishes an exited recorded process from no PID evidence.
        let processLiveness: RestorableAgentProcessLiveness
        /// Whether the persisted owner record carried a PID. A PID-less hook
        /// record is durable post-exit state for stable ownership selection;
        /// its liveness remains tri-state for shell-activity persistence.
        let hasRecordedProcessID: Bool
        let processIDs: Set<Int>
        let processIdentities: [Int: AgentPIDProcessIdentity]
        let agentProcessIDs: Set<Int>
        let agentProcessIdentities: [Int: AgentPIDProcessIdentity]
        let hibernationPanelProcessIDs: Set<Int>
        let terminationProcessIDs: Set<Int>
        let terminationProcessIdentities: [Int: AgentPIDProcessIdentity]
        let containsUnrelatedProcess: Bool

        /// Keeps older in-process fixtures source-compatible while callers that
        /// have persisted PID evidence can opt in explicitly.
        init(
            snapshot: SessionRestorableAgentSnapshot,
            lifecycle: AgentHibernationLifecycleState?,
            runtimeStatusEventTime: TimeInterval? = nil,
            updatedAt: TimeInterval,
            processLiveness: RestorableAgentProcessLiveness,
            hasRecordedProcessID: Bool = false,
            processIDs: Set<Int>,
            processIdentities: [Int: AgentPIDProcessIdentity],
            agentProcessIDs: Set<Int>,
            agentProcessIdentities: [Int: AgentPIDProcessIdentity],
            hibernationPanelProcessIDs: Set<Int>,
            terminationProcessIDs: Set<Int>,
            terminationProcessIdentities: [Int: AgentPIDProcessIdentity],
            containsUnrelatedProcess: Bool
        ) {
            self.snapshot = snapshot
            self.lifecycle = lifecycle
            self.runtimeStatusEventTime = runtimeStatusEventTime
            self.updatedAt = updatedAt
            self.processLiveness = processLiveness
            self.hasRecordedProcessID = hasRecordedProcessID
            self.processIDs = processIDs
            self.processIdentities = processIdentities
            self.agentProcessIDs = agentProcessIDs
            self.agentProcessIdentities = agentProcessIdentities
            self.hibernationPanelProcessIDs = hibernationPanelProcessIDs
            self.terminationProcessIDs = terminationProcessIDs
            self.terminationProcessIdentities = terminationProcessIdentities
            self.containsUnrelatedProcess = containsUnrelatedProcess
        }
    }

}
