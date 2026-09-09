import CmuxNotifications
import CmuxSettings
import Foundation

extension TerminalMutationBus {
    struct QueuedTerminalNotificationKey: Hashable, Sendable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    struct QueuedTerminalNotification: Sendable {
        let key: QueuedTerminalNotificationKey
        let title: String
        let subtitle: String
        let body: String
        let replyShape: TerminalNotificationReplyShape
        let agent: TerminalNotificationPolicyAgentContext?
        let soundContext: NotificationSoundOverrideContext?
        let correlationKey: String?
        let agentStatusKey: String?
        let agentEventTime: TimeInterval?
    }

    enum TerminalSocketMutation {
        case deliverNotification(QueuedTerminalNotification)
        case clearAllNotifications(through: UInt64)
        case clearNotificationsForTab(UUID, through: UInt64)
        case clearNotificationsForSurface(UUID, UUID, through: UInt64)
        case clearNotificationsForCorrelation(UUID, UUID, String, through: UInt64)
        case clearAgentNotifications(
            claimedTabId: UUID,
            surfaceId: UUID,
            statusKey: String,
            eventTime: TimeInterval,
            through: UInt64
        )
        case perform(@MainActor () -> Void)
    }

    struct TerminalSocketMutationEntry {
        let sequence: UInt64
        let mutation: TerminalSocketMutation
        let notificationGeneration: UInt64?
        let notificationCoalescingKey: TerminalNotificationCoalescingKey?
        let performReplaceKey: TerminalMutationReplaceKey?
    }

    struct TerminalNotificationCoalescingKey: Hashable {
        let generation: UInt64
        let notificationKey: QueuedTerminalNotificationKey
    }
}
