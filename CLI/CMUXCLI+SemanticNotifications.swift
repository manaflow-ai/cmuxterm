import CmuxAgentJournal
import Foundation

extension CMUXCLI {
    /// Converts adapter evidence and existing localized presentation into one journal candidate.
    /// Lifecycle reconciliation, receipts, policy, and effect delivery are owned by the app.
    func semanticNotificationCommand(
        source: String, agentKey: String, sessionId: String?,
        workspaceId: String, surfaceId: String, kind: AgentJournalEventKind,
        rawObject: [String: Any]?, payload: String, pendingWork: Bool = false,
        eventTimeOverride: TimeInterval? = nil
    ) throws -> String {
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { throw CLIError(message: String(localized: "cli.notification.invalidPayload", defaultValue: "Invalid notification payload")) }
        let meta = fields.count > 3 ? fields[3].split(separator: ";").map(String.init) : []
        let category = meta.first { $0.hasPrefix("c=") }.map { String($0.dropFirst(2)) }
            ?? (kind == .turnCompleted ? "turn-complete" : "other")
        // Legacy payloads end in k=<status-key>;t=<event-time>. That k is
        // ordering metadata, not a notification identity shared by every turn.
        let correlationKey = meta.enumerated().first { index, field in
            field.hasPrefix("k=") && (index + 1 == meta.count || !meta[index + 1].hasPrefix("t="))
        }.map { String($0.element.dropFirst(2)) }
        let notification = AgentJournalNotification(title: fields[0], subtitle: fields[1], body: fields[2],
            category: category, correlationKey: correlationKey)
        return try semanticNotificationCommand(source: source, agentKey: agentKey, sessionId: sessionId,
            workspaceId: workspaceId, surfaceId: surfaceId, kind: kind, rawObject: rawObject,
            notification: notification, pendingWork: pendingWork || meta.contains("p=1"), isSubagent: meta.contains("n=1"),
            eventTimeOverride: eventTimeOverride)
    }

    func semanticNotificationCommand(
        source: String, agentKey: String, sessionId: String?, workspaceId: String, surfaceId: String,
        kind: AgentJournalEventKind, rawObject: [String: Any]?, notification: AgentJournalNotification,
        pendingWork: Bool = false, isSubagent: Bool = false,
        eventTimeOverride: TimeInterval? = nil
    ) throws -> String {
        var context = Self.semanticAttentionContext(rawObject)
        var notification = notification
        switch kind {
        case .errorReported, .messagePublished: notification.category = "other"
        case .turnCompleted: notification.category = "turn-complete"
        case .idleObserved: notification.category = "idle-reminder"
        case .approvalRequested, .planReviewRequested: notification.category = "needs-permission"
        default: break
        }
        context.notification = notification
        if context.requestIdentity == nil { context.requestIdentity = notification.correlationKey }
        let rejectedCapture = Self.agentHookCaptureTimeIsInvalid
        let draft = AgentJournalEventDraft(kind: kind,
            occurredAtMs: Self.semanticOccurredAtMs(rawObject, eventTimeOverride: eventTimeOverride)
                ?? Int64(Date().timeIntervalSince1970 * 1000),
            source: source, agentKey: agentKey, sessionId: sessionId,
            workspaceId: rejectedCapture ? nil : workspaceId, surfaceId: rejectedCapture ? nil : surfaceId,
            unattributedReason: rejectedCapture ? "invalid-hook-event-time" : nil,
            isSubagent: isSubagent, pendingWork: pendingWork,
            nativeEvent: rawObject?["hook_event_name"] as? String, attention: context)
        let data = try JSONEncoder().encode(draft)
        return "agent_journal_append \(String(decoding: data, as: UTF8.self))"
    }

    static func semanticAttentionContext(_ object: [String: Any]?) -> AgentAttentionContext {
        func identifier(_ keys: [String]) -> String? {
            for key in keys {
                if let value = object?[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        // Identical prompts and responses can be different real turns. Only
        // native IDs identify replays; identity-less hooks use lifecycle generations.
        return AgentAttentionContext(
            eventIdentity: identifier(["event_id", "eventId", "message_id", "uuid"]),
            turnIdentity: identifier(["turn_id", "turnId"]),
            requestIdentity: identifier(["tool_use_id", "toolUseId", "toolUseID", "tool_call_id", "toolCallId", "request_id", "requestId"]))
    }

    static func semanticOccurredAtMs(
        _ object: [String: Any]?,
        eventTimeOverride: TimeInterval? = nil
    ) -> Int64? {
        // The wrapper captures time before detaching. Processing time would
        // make an older, delayed Running hook look newer than Stop again.
        if let eventTimeOverride {
            return Int64((eventTimeOverride * 1000).rounded())
        }
        if let captured = ProcessInfo.processInfo.environment["CMUX_AGENT_HOOK_CAPTURED_AT"] {
            return parseAgentHookTimeValue(captured).map { Int64(($0 * 1000).rounded()) }
        }
        for key in ["occurred_at_ms", "timestamp_ms"] {
            if let value = object?[key] as? NSNumber, value.int64Value >= 0 { return value.int64Value }
        }
        return parseAgentHookEventTime(rawObject: object).map { Int64(($0 * 1000).rounded()) }
    }

    /// A failed clock may not project state, but permission hooks must still
    /// run and return their decision. Keep their journal entry diagnostic-only.
    static var agentHookCaptureTimeIsInvalid: Bool {
        guard let captured = ProcessInfo.processInfo.environment["CMUX_AGENT_HOOK_CAPTURED_AT"] else {
            return false
        }
        return parseAgentHookTimeValue(captured) == nil
    }
}
