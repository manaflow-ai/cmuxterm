public import Foundation

/// Decides whether a captured agent event may update one pane's runtime state.
///
/// Same-agent status and lifecycle writes may share a timestamp. A replacement
/// agent must be strictly newer than the prior agent's watermark so delayed
/// callbacks cannot revive a replaced session. This value does not own or mutate
/// runtime state; Workspace and Dock apply its result to their existing stores.
///
/// ```swift
/// let admission = AgentRuntimeMutationAdmission(
///     lifecycleEventTime: 100, statusEventTime: 100, replacementWatermark: nil,
///     agentEventTime: 101, enforceOrdering: true, retainAcceptedEventTime: true
/// )
/// if admission.isAccepted { /* Apply the event to the owning store. */ }
/// ```
public struct AgentRuntimeMutationAdmission: Sendable {
    /// Whether the incoming mutation satisfies every applicable watermark.
    public let isAccepted: Bool

    /// The accepted timestamp to retain, or `nil` when retention is not requested.
    public let retainedEventTime: TimeInterval?

    /// Evaluates the event against a snapshot of the pane's ordering authority.
    ///
    /// - Parameters:
    ///   - lifecycleEventTime: Latest event retained by the lifecycle store.
    ///   - statusEventTime: Latest event retained by the visible status entry.
    ///   - replacementWatermark: Event time of an agent being replaced on the pane.
    ///   - agentEventTime: Captured time of the incoming event, not its delivery time.
    ///   - enforceOrdering: Whether this is an ordered hook mutation or internal cleanup.
    ///   - retainAcceptedEventTime: Whether this bounded agent key retains a durable watermark.
    public init(
        lifecycleEventTime: TimeInterval?,
        statusEventTime: TimeInterval?,
        replacementWatermark: TimeInterval?,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        retainAcceptedEventTime: Bool
    ) {
        guard enforceOrdering else {
            isAccepted = true
            retainedEventTime = nil
            return
        }
        guard let agentEventTime else {
            isAccepted = false
            retainedEventTime = nil
            return
        }
        isAccepted = (replacementWatermark.map { agentEventTime > $0 } ?? true)
            && (lifecycleEventTime.map { agentEventTime >= $0 } ?? true)
            && (statusEventTime.map { agentEventTime >= $0 } ?? true)
        retainedEventTime = isAccepted && retainAcceptedEventTime ? agentEventTime : nil
    }
}
