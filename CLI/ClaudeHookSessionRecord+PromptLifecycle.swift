import CmuxAgentHooks

extension ClaudeHookSessionRecord {
    private mutating func advancePromptLifecycleRevision() {
        let current = promptLifecycleRevision ?? 0
        promptLifecycleRevision = current == Int64.max ? 0 : current + 1
    }

    private var promptLifecycleState: AgentHookPromptLifecycleState {
        get {
            AgentHookPromptLifecycleState(
                depth: activePromptDepth,
                activeTurnID: activePromptTurnId,
                activeTurnIDs: activePromptTurnIds,
                lastTurnID: lastPromptTurnId
            )
        }
        set {
            activePromptDepth = newValue.depth
            activePromptTurnId = newValue.activeTurnID
            activePromptTurnIds = newValue.activeTurnIDs
            lastPromptTurnId = newValue.lastTurnID
        }
    }

    /// Starts an authoritative prompt in the persisted session projection.
    mutating func beginAuthoritativePrompt(turnId: String?) {
        let wasActive = (activePromptDepth ?? 0) > 0
        let previousActiveTurnId = activePromptTurnId ?? activePromptTurnIds?.last
        var state = promptLifecycleState
        state.beginAuthoritativePrompt(turnID: turnId)
        promptLifecycleState = state
        // Antigravity emits PreInvocation once per model invocation within a
        // single turn. Keep those repeated callbacks in one generation, while
        // still fencing a new turn when it has an explicit, changed ID.
        if !wasActive || (turnId != nil && turnId != previousActiveTurnId) {
            advancePromptLifecycleRevision()
        }
    }

    /// Closes all active prompt state while retaining the most recent turn id.
    /// The prompt revision identifies the prompt generation, so terminal
    /// callbacks that captured it before this close must remain valid when
    /// they are concurrent same-turn completions.
    mutating func endAuthoritativePrompt() {
        var state = promptLifecycleState
        state.endAuthoritativePrompt()
        promptLifecycleState = state
    }

    /// Clears active prompt fields while retaining the most recently observed turn identifier.
    mutating func clearActivePromptState() {
        var state = promptLifecycleState
        state.clearActivePromptState()
        promptLifecycleState = state
        advancePromptLifecycleRevision()
    }

    /// Clears active and completed prompt markers at a fresh session boundary.
    mutating func clearPromptStartState() {
        var state = promptLifecycleState
        state.clearPromptStartState()
        promptLifecycleState = state
        advancePromptLifecycleRevision()
    }
}

extension CMUXCLI.AgentHookDef {
    /// Derives prompt-depth semantics from the adapter's prompt-start contract.
    var promptDepthPolicy: AgentHookPromptDepthPolicy {
        promptStartIsAuthoritative ? .authoritative : .balanced
    }
}
