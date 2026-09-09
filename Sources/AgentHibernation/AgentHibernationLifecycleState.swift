import CmuxAgentLifecycle

typealias AgentHibernationLifecycleState =
    CmuxAgentLifecycle.AgentLifecycleState

extension CmuxAgentLifecycle.AgentLifecycleState {
    static func aggregate(
        statusKeyedStates: [String: Self],
        fallback: Self?
    ) -> Self {
        let states = statusKeyedStates
            .filter { !CmuxAgentLifecycle.AgentLifecycleStatusKey(rawValue: $0.key).isManual }
            .map(\.value)
        guard !states.isEmpty else {
            return fallback ?? .unknown
        }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    /// Restricts TextBox Escape authorization to the fixed built-in agent set.
    /// Custom and manual lifecycle keys remain valid for hibernation state, but
    /// cannot authorize a control key to an arbitrary process.
    static func aggregateForTextBoxEscape(
        statusKeyedStates: [String: Self]
    ) -> Self {
        var hasNeedsInput = false
        var hasUnknown = false
        var hasIdle = false

        for key in CmuxAgentLifecycle.AgentLifecycleStatusKey.allowedStatusKeys {
            guard let state = statusKeyedStates[key] else { continue }
            switch state {
            case .running:
                return .running
            case .needsInput:
                hasNeedsInput = true
            case .unknown:
                hasUnknown = true
            case .idle:
                hasIdle = true
            }
        }

        if hasNeedsInput { return .needsInput }
        if hasUnknown { return .unknown }
        if hasIdle { return .idle }
        return .unknown
    }
}
