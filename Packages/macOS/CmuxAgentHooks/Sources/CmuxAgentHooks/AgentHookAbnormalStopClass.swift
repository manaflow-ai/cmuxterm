/// Stable provider failure classes that terminate a turn without completing it.
/// The enum is deliberately UI-neutral so hook consumers can share the
/// classification contract without importing the app target.
public enum AgentHookAbnormalStopClass: Equatable, Sendable, CaseIterable {
    case capacity
    case quota
    case rateLimit
    case timeout
    case authentication
    case network
    case generic
}
