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

}
