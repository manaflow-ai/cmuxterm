import Foundation

extension CMUXCLI {
    /// Reads the wrapper-captured timestamp before payload fallbacks so every
    /// detached hook process shares one ordering authority.
    static func parseAgentHookEventTime(rawObject: [String: Any]?) -> TimeInterval? {
        if let rawCaptured = ProcessInfo.processInfo.environment["CMUX_AGENT_HOOK_CAPTURED_AT"] {
            // An explicitly empty capture means the ordering authority was
            // unavailable; do not silently fall back to a lower-confidence
            // payload timestamp.
            return parseAgentHookTimeValue(rawCaptured)
        }
        let keys = [
            "cmux_event_time", "cmuxEventTime",
            "event_time", "eventTime",
            "timestamp", "created_at", "createdAt",
        ]
        if let rawObject {
            for key in keys {
                if let parsed = parseAgentHookTimeValue(rawObject[key]) {
                    return parsed
                }
            }
        }
        return nil
    }

    static func parseAgentHookTimeValue(_ rawValue: Any?) -> TimeInterval? {
        switch rawValue {
        case let number as NSNumber:
            return normalizeAgentHookEpochSeconds(number.doubleValue)
        case let value as Double:
            return normalizeAgentHookEpochSeconds(value)
        case let value as Int:
            return normalizeAgentHookEpochSeconds(TimeInterval(value))
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let value = Double(trimmed) {
                return normalizeAgentHookEpochSeconds(value)
            }
            guard let timestamp = parseAgentHookISO8601TimeValue(trimmed) else { return nil }
            return normalizeAgentHookEpochSeconds(timestamp)
        default:
            return nil
        }
    }

    private static func normalizeAgentHookEpochSeconds(_ rawValue: TimeInterval) -> TimeInterval? {
        guard rawValue.isFinite, rawValue > 0 else { return nil }
        let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
        guard seconds >= 946_684_800,
              seconds <= Date.now.timeIntervalSince1970 + 5 * 60 else { return nil }
        return seconds
    }

    private static func parseAgentHookISO8601TimeValue(_ value: String) -> TimeInterval? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date.timeIntervalSince1970
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)?.timeIntervalSince1970
    }

}
