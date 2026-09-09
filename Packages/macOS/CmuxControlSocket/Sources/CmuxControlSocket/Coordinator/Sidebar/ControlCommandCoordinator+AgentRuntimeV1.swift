import Foundation

/// The v1 sidebar metadata commands (`set_status` / `report_meta` /
/// `report_meta_block` / agent PID + lifecycle / `log` / `set_progress` and
/// their clears + listings), lifted byte-faithfully from the former
/// `TerminalController` bodies. Parsing and reply formatting run here; live
/// app reach goes through ``ControlSidebarContext``.
///
/// Every body is `nonisolated` (the socket dispatcher's v1 worker lane runs
/// them on the connection thread): parse/validation/formatting run on the
/// calling thread, deferred mutations go through the `nonisolated`
/// `Schedule*` seam witnesses (mutation-bus enqueues), and each command
/// crosses to the main actor at most once via
/// ``ControlSidebarContext/controlSidebarOnMain(_:)`` for its synchronous
/// resolution read/write. The seam is threaded as a parameter because the
/// coordinator's `context` property is main-actor-isolated.

extension ControlCommandCoordinator {
    /// `set_agent_pid` — register an agent PID for stale-session detection
    /// (parse + bus enqueue; zero main hops).
    nonisolated func sidebarSetAgentPID(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "set_agent_pid <key> <pid> [--tab=<id>] [--panel=<id>] [--agent-event-time=<seconds>]"
        guard parsed.positional.count >= 2,
              let pid = Int32(parsed.positional[1]), pid > 0 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        let agentEventTimeResult = sidebarParseAgentEventTime(parsed.options["agent-event-time"])
        let agentEventTime: TimeInterval?
        switch agentEventTimeResult {
        case .absent:
            agentEventTime = nil
        case .valid(let value):
            agentEventTime = value
        case .invalid(let raw):
            return sidebarInvalidAgentEventTimeError(raw, context: context)
        }
        context?.controlSidebarScheduleAgentPIDRecord(
            target: target,
            key: key,
            pid: pid,
            panelID: panelResolution.panelId,
            agentEventTime: agentEventTime
        )
        return "OK"
    }

    /// `set_agent_lifecycle` — record a restorable agent session's lifecycle.
    /// The vault-registry allowlist check
    /// (`controlSidebarIsAllowedAgentLifecycleKey`) owns this command's single
    /// main hop app-side: it snapshots the tab/panel directory candidates on
    /// main and runs the registry disk IO on the calling thread.
    nonisolated func sidebarSetAgentLifecycle(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "set_agent_lifecycle <key> <unknown|running|idle|needsInput> [--tab=<id>] [--panel=<id>] [--agent-event-time=<seconds>]"
        guard parsed.positional.count >= 2 else {
            return "ERROR: Usage: \(usage)"
        }
        let key = parsed.positional[0]
        let rawLifecycle = parsed.positional[1]
        guard let lifecycleRawValue = context?.controlSidebarParseAgentLifecycle(rawLifecycle) else {
            return "ERROR: Invalid agent lifecycle '\(parsed.positional[1])' — usage: \(usage)"
        }
        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        let agentEventTimeResult = sidebarParseAgentEventTime(parsed.options["agent-event-time"])
        let agentEventTime: TimeInterval?
        switch agentEventTimeResult {
        case .absent:
            agentEventTime = nil
        case .valid(let value):
            agentEventTime = value
        case .invalid(let raw):
            return sidebarInvalidAgentEventTimeError(raw, context: context)
        }
        guard context?.controlSidebarIsAllowedAgentLifecycleKey(
            key,
            target: target,
            panelID: panelResolution.panelId
        ) ?? false else {
            return "ERROR: Unsupported agent lifecycle key '\(key)'"
        }
        context?.controlSidebarScheduleAgentLifecycle(
            target: target,
            key: key,
            lifecycleRawValue: lifecycleRawValue,
            panelID: panelResolution.panelId,
            agentEventTime: agentEventTime
        )
        return "OK"
    }

    /// `agent_hibernation` — the global hibernation toggle (the seam witness
    /// applies the settings write in its own single main hop so the change
    /// notification still posts on the main thread and the reply stays
    /// apply-then-reply, as the legacy body was).
    nonisolated func sidebarAgentHibernation(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let subcommand = parsed.positional.first?.lowercased()
        let usage = "agent_hibernation <on|off>"

        switch subcommand {
        case "on", "enable", "enabled", "true":
            context?.controlSidebarSetAgentHibernation(enabled: true)
            return "OK"
        case "off", "disable", "disabled", "false":
            context?.controlSidebarSetAgentHibernation(enabled: false)
            return "OK"
        default:
            return "ERROR: Usage: \(usage)"
        }
    }

    /// `clear_agent_pid` — unregister an agent PID (parse + bus enqueue; zero
    /// main hops).
    nonisolated func sidebarClearAgentPID(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        let usage = "clear_agent_pid <key> [--tab=<id>] [--panel=<id>] [--clear-status] [--agent-event-time=<seconds>]"
        guard let key = parsed.positional.first else {
            return "ERROR: Usage: \(usage)"
        }
        let targetResolution = sidebarParseMutationTabTarget(options: parsed.options)
        guard let target = targetResolution.target else {
            return targetResolution.error ?? "ERROR: No tab selected"
        }
        let panelResolution = sidebarParseOptionalPanelIdOption(options: parsed.options, usage: usage)
        if let error = panelResolution.error {
            return error
        }
        let agentEventTimeResult = sidebarParseAgentEventTime(parsed.options["agent-event-time"])
        let agentEventTime: TimeInterval?
        switch agentEventTimeResult {
        case .absent:
            agentEventTime = nil
        case .valid(let value):
            agentEventTime = value
        case .invalid(let raw):
            return sidebarInvalidAgentEventTimeError(raw, context: context)
        }
        context?.controlSidebarScheduleAgentPIDClear(
            target: target,
            key: key,
            panelID: panelResolution.panelId,
            clearStatus: parsed.options["clear-status"] != nil,
            agentEventTime: agentEventTime,
            requireOwnedKey: parsed.options["require-owned-key"] != nil
        )
        return "OK"
    }

}
