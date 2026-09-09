import Foundation
import CmuxSettings

/// Category tag the app uses to gate agent notifications by user config.
/// Serialized into the `notify_target_async` payload's optional meta segment.
enum AgentHookNotifyCategory: String {
    case turnComplete = "turn-complete"
    case needsPermission = "needs-permission"
    case idleReminder = "idle-reminder"
    case other

    var soundAlertType: NotificationSoundAlertType? {
        switch self {
        case .turnComplete: return .turnDone
        case .needsPermission, .idleReminder: return .needsInput
        case .other: return nil
        }
    }

    /// Legacy delimiter-safe meta segment: `c=<category>;p=<0|1>`. The
    /// contextual overload below adds the agent and alert identity.
    func metaSegment(pending: Bool) -> String? {
        metaSegment(pending: pending, agentKind: nil, isSubagent: nil)
    }

    /// Extended meta segment carrying optional sound and agent-event context
    /// for the app's notification-policy hooks. The final `k=/t=` pair is the
    /// ordered status watermark; an earlier `k=` is an opaque notification
    /// identity.
    /// An agent kind or correlation key that fails validation is dropped rather
    /// than risking the app-side parser folding the whole meta back into the
    /// body.
    func metaSegment(
        pending: Bool,
        agentKind: String?,
        isSubagent: Bool?,
        correlationKey: String? = nil,
        statusKey: String? = nil,
        eventTime: TimeInterval? = nil
    ) -> String? {
        guard self != .other || (statusKey != nil && eventTime != nil) else { return nil }
        var segment = "c=\(rawValue);p=\(pending ? 1 : 0)"
        if let agentKind, Self.isValidAgentKindTag(agentKind) {
            segment += ";a=\(agentKind)"
        }
        if let isSubagent {
            segment += ";n=\(isSubagent ? 1 : 0)"
        }
        if let correlationKey, Self.isValidCorrelationKey(correlationKey) {
            segment += ";k=\(UUID(uuidString: correlationKey)?.uuidString.lowercased() ?? correlationKey)"
        }
        if let statusKey,
           !statusKey.isEmpty,
           statusKey.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
           let eventTime,
           eventTime.isFinite,
           eventTime >= 946_684_800,
           eventTime <= Date.now.timeIntervalSince1970 + 5 * 60 {
            segment += ";k=\(statusKey);t=\(AgentHookWireFormat.eventTime(eventTime))"
        }
        return segment
    }

    /// Mirror of the app-side `AgentNotificationMeta` slug grammar: 1-64 ASCII
    /// characters of `[A-Za-z0-9._-]`, excluding `.` and `..`. Both sides must
    /// agree exactly or the app folds the meta back into the notification body.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        NotificationSoundOverrideContext.isValidAgentID(value)
    }

    func metaSegment(
        pending: Bool,
        agentID: String,
        alertType: NotificationSoundAlertType? = nil,
        isSubagent: Bool? = nil,
        correlationKey: String? = nil,
        statusKey: String? = nil,
        eventTime: TimeInterval? = nil
    ) -> String? {
        let resolvedAlertType: NotificationSoundAlertType?
        switch self {
        case .turnComplete: resolvedAlertType = alertType ?? .turnDone
        case .needsPermission, .idleReminder: resolvedAlertType = alertType ?? .needsInput
        case .other: resolvedAlertType = alertType
        }
        guard let resolvedAlertType,
              let context = NotificationSoundOverrideContext(
                  agentID: agentID,
                  alertType: resolvedAlertType
              ),
              (self == .other
                ? resolvedAlertType == .errorStalled
                : soundAlertType == resolvedAlertType) else {
            return nil
        }
        var segment = "c=\(rawValue);p=\(pending ? 1 : 0);a=\(context.agentID)"
        if let isSubagent {
            segment += ";n=\(isSubagent ? 1 : 0)"
        }
        segment += ";s=\(context.alertType.rawValue)"
        if let correlationKey, Self.isValidCorrelationKey(correlationKey) {
            segment += ";k=\(UUID(uuidString: correlationKey)?.uuidString.lowercased() ?? correlationKey)"
        }
        if let statusKey,
           !statusKey.isEmpty,
           statusKey.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
           let eventTime,
           eventTime.isFinite,
           eventTime >= 946_684_800,
           eventTime <= Date.now.timeIntervalSince1970 + 5 * 60 {
            segment += ";k=\(statusKey);t=\(AgentHookWireFormat.eventTime(eventTime))"
        }
        return segment
    }

    /// Correlation keys are opaque UUIDs used only to clear one notification.
    static func isValidCorrelationKey(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}
