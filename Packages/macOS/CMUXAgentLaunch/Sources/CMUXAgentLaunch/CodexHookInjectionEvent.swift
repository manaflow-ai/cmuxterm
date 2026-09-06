/// One event entry in a cmux-generated Codex hook argument block.
public struct CodexHookInjectionEvent: Equatable, Sendable {
    /// The Codex hook event configured by this entry.
    public let agentEvent: String

    /// The cmux hook subcommand invoked for the event.
    public let cmuxSubcommand: String

    /// The timeout Codex applies to the hook command, in milliseconds.
    public let timeoutMs: Int

<<<<<<< ours
    /// Whether the hook must finish its cmux-owned lifecycle write before
    /// Codex advances to the next event. Completion/status hooks remain
    /// fire-and-forget; child lifecycle events use the synchronous boundary.
    public let isSynchronous: Bool

    /// Creates one generated Codex hook event.
=======
    /// Whether the hook may return after bounded queue admission or must keep
    /// the direct process/stdout contract for an agent decision.
    public let delivery: CodexHookDelivery

    /// Creates one schema entry. Queue delivery is the safe default for
    /// lifecycle and telemetry events; decision events opt into `.direct`.
>>>>>>> theirs
    public init(
        agentEvent: String,
        cmuxSubcommand: String,
        timeoutMs: Int,
<<<<<<< ours
        isSynchronous: Bool = false
=======
        delivery: CodexHookDelivery = .queued
>>>>>>> theirs
    ) {
        self.agentEvent = agentEvent
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
<<<<<<< ours
        self.isSynchronous = isSynchronous
    }
=======
        self.delivery = delivery
    }
}

/// The execution contract for a cmux-injected Codex hook.
public enum CodexHookDelivery: Equatable, Sendable {
    case queued
    case direct
>>>>>>> theirs
}
