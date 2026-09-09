import Foundation


extension TerminalMutationBus {
    @MainActor
    func perform(_ batch: [TerminalSocketMutationEntry]) {
        for entry in batch {
            switch entry.mutation {
            case .deliverNotification(let notification):
#if DEBUG
                cmuxDebugLog(
                    "notification.queue.perform seq=\(entry.sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
                )
#endif
                TerminalNotificationStore.shared.deliverQueuedNotification(
                    claimedTabId: notification.key.tabId,
                    surfaceId: notification.key.surfaceId,
                    title: notification.title,
                    subtitle: notification.subtitle,
                    body: notification.body,
                    replyShape: notification.replyShape,
                    agent: notification.agent,
                    correlationKey: notification.correlationKey,
                    notificationGeneration: entry.notificationGeneration ?? 0,
                    soundContext: notification.soundContext,
                    agentStatusKey: notification.agentStatusKey,
                    agentEventTime: notification.agentEventTime
                )
            case .clearAllNotifications(let boundary):
                TerminalNotificationStore.shared.clearAll(discardQueuedNotifications: false, throughNotificationGeneration: boundary)
            case .clearNotificationsForTab(let tabId, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForSurface(let tabId, let surfaceId, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForCorrelation(let tabId, let surfaceId, let correlationKey, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    correlationKey: correlationKey,
                    throughNotificationGeneration: boundary
                )
            case .clearAgentNotifications(
                claimedTabId: let claimedTabId,
                surfaceId: let surfaceId,
                statusKey: let statusKey,
                eventTime: let eventTime,
                through: let boundary
            ):
                guard let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
                    claimedTabId: claimedTabId,
                    surfaceId: surfaceId
                ), let liveSurfaceId = target.surfaceId else { continue }
                guard let owner = TerminalController.shared.controlSidebarResolvePanelOwner(
                    target: .workspace(target.tabId),
                    panelID: liveSurfaceId
                ), owner.acceptAgentRuntimeMutation(
                    statusKey: statusKey,
                    panelId: liveSurfaceId,
                    agentEventTime: eventTime,
                    enforceOrdering: true
                ) else {
                    continue
                }
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: target.tabId,
                    surfaceId: liveSurfaceId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .perform(let mutation):
                mutation()
            }
        }
    }
}
