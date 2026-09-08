import Foundation
import CmuxAgentHooks

extension AgentHookNotificationSummary {
    static let maxBodyLength = 180

    static func truncatedBody(_ value: String) -> String {
        guard value.count > maxBodyLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxBodyLength - 1))
        return String(value[..<index]) + "…"
    }
}

extension AgentHookNotificationClassifier {
    static func abnormalStopSummary(
        displayName: String,
        signal: String,
        message: String,
        isFallback: Bool
    ) -> AgentHookNotificationSummary? {
        let classifier = AgentHookAbnormalStopClassifier()
        guard classifier.isStopSignal(signal) else { return nil }
        return classifier.summary(
            displayName: displayName,
            signal: signal,
            message: message,
            isFallback: isFallback
        )
    }

    static func isUserInitiatedStop(signal: String, message: String) -> Bool {
        let classifier = AgentHookAbnormalStopClassifier()
        return classifier.isStopSignal(signal)
            && classifier.isUserInitiatedStop(signal: signal, message: message)
    }
}

extension AgentHookNotificationPolicy {
    /// Redacts credentials before a command reaches durable hook state or UI.
    static func redactSensitiveCommand(_ value: String) -> String {
        let boundedValue = value.utf8.count > 8_192
            ? String(decoding: value.utf8.prefix(8_191), as: UTF8.self) + "…"
            : value
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"(?i)\b(?:authorization|proxy-authorization)\s*:\s*[^\s'\";&|]+(?:\s+[^\s'\";&|]+)*"#, "<credential>:<token>"),
            (#"(?i)\b(?:x[-_])?(?:api[-_]?key|password|passwd|secret|token|authorization|cookie|pass)\s*:\s*(?:Bearer\s+)?(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, "<credential>:<token>"),
            (#"(?i)(?:^|\s)--?[A-Za-z0-9]*(?:api[-_]?key|access[-_]?key|password|passwd|secret|token|authorization|cookie|passphrase|pass)[A-Za-z0-9_-]*(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)--?(?:api[-_]?key|password|passwd|secret|token|authorization|cookie|passphrase|pass)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, "<credential>=<token>"),
            (#"(?i)(?:^|\s)(?:-u|--user)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)(?:^|\s)(?:--passphrase|--password|--passwd|--pass|--auth|--credential)(?:=|\s+)(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)(?:^|\s)(?:-a|-p|-pass)(?:=|\s+|(?=[^\s]))(?:'[^']*'|\"[^\"]*\"|[^\s'\";&|]+)"#, " <credential>"),
            (#"(?i)\b[A-Za-z_]*(?:api[_-]?key|access[_-]?key|password|passwd|secret|token|authorization|cookie|passphrase|pass)[A-Za-z0-9_]*\s*=\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#, "<credential>=<token>"),
            (#"(?i)\b(?:api[_-]?key|access[_-]?key|password|passwd|secret|token|authorization|cookie|passphrase|pass)\s*=\s*[^\s;&|]+"#, "<credential>=<token>"),
            (#"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b"#, "<token>"),
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#, "Bearer <token>"),
            (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>"),
        ]
        return patterns.reduce(boundedValue) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }
}

extension CMUXCLI {
    func sanitizeNotificationField(_ value: String) -> String {
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    func notificationPayload(
        title: String,
        subtitle: String,
        body: String,
        meta: String? = nil
    ) -> String {
        let base = "\(sanitizeNotificationField(title))|\(sanitizeNotificationField(subtitle))|\(sanitizeNotificationField(body))"
        // `meta` is a structured, delimiter-safe tag: it has no
        // "|" or spaces, so it is NOT sanitized and rides as a 4th pipe segment.
        // Omitting it reproduces the exact 3-field payload every legacy caller sends.
        guard let meta, !meta.isEmpty else { return base }
        return base + "|" + meta
    }

    /// True when a Claude `Stop`/`Notification` payload reports unfinished
    /// background work: any `background_tasks` entry still `running`, or a
    /// non-empty `session_crons`. A `nil` rawObject or absent keys (claude
    /// < 2.1.145) yield `false`, so older clients behave exactly as before.
    /// Pure over `rawObject` so both the notify gate and the hibernation
    /// lifecycle decision can share it (mirrors `hasActiveAntigravityBackgroundWork`).
    func hasActiveClaudeBackgroundWork(_ parsedInput: ClaudeHookParsedInput) -> Bool {
        guard let obj = parsedInput.rawObject else { return false }
        if let crons = obj["session_crons"] as? [Any], !crons.isEmpty { return true }
        if let tasks = obj["background_tasks"] as? [[String: Any]] {
            return tasks.contains { ($0["status"] as? String) == "running" }
        }
        return false
    }

    func summarizeClaudeHookNotification(parsedInput: ClaudeHookParsedInput) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyClaudeNotification(signal: fallback, message: fallback)
            }
            // No payload at all: nothing to say. An empty body tells the
            // caller to reuse the stored session summary or skip the banner —
            // never to fabricate a needs-attention message.
            return ("Waiting", "")
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let message = messageCandidates.compactMap { $0 }.first ?? ""
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? String(localized: "agent.generic.notification.body.approvalNeeded", defaultValue: "Approval needed") : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? String(localized: "cli.claude-hook.notification.body.error", defaultValue: "Claude reported an error") : message
            return ("Error", body)
        }
        if AgentHookNotificationClassifier.containsCompletionCue(lower) {
            let body = message.isEmpty ? String(localized: "agent.generic.notification.body.taskCompleted", defaultValue: "Task completed") : message
            return ("Completed", body)
        }
        if AgentHookNotificationClassifier.containsWaitingCue(lower) {
            let body = message.isEmpty ? String(localized: "agent.generic.notification.body.waitingForInput", defaultValue: "Waiting for input") : message
            return ("Waiting", body)
        }
        // Use the message directly when there is one. A payload with no
        // usable message yields an empty body: callers reuse the stored
        // session summary or skip the banner. The old "Claude needs your
        // attention" fabrication (and the needs-input state it implied) is
        // deliberately gone — an unparseable message is not a signal.
        if !message.isEmpty {
            return ("Attention", message)
        }
        return ("Attention", "")
    }

    /// Classifier tokens are internal protocol values; only this boundary renders them.
    func localizedClaudeNotificationSubtitle(_ token: String) -> String {
        switch token {
        case "Permission": String(localized: "agent.generic.notification.subtitle.permission", defaultValue: "Permission")
        case "Waiting": String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting")
        case "Error": String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error")
        case "Completed": String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed")
        case "Attention": String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention")
        default: token
        }
    }
}
