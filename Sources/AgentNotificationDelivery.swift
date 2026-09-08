import CmuxSettings
import CmuxNotifications
import Foundation

/// Applies agent notification policy and publishes accepted events through the shared mutation bus.
struct AgentNotificationDelivery: Sendable {
    private let permissionEnabled: Bool
    private let turnMode: AgentTurnCompleteMode
    private let idleEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        let catalog = NotificationsCatalogSection()
        self.permissionEnabled = catalog.agentPermissionPrompt.value(in: defaults)
        self.turnMode = AgentTurnCompleteMode(
            rawValue: catalog.agentTurnComplete.value(in: defaults)
        ) ?? .whenIdle
        self.idleEnabled = catalog.agentIdleReminder.value(in: defaults)
    }

    /// Gates and enqueues the same notification event for hooks and PTY prompt detectors.
    /// Approval correlation is used only for needs-permission events; agent
    /// context remains available for all other categories.
    @discardableResult
    func enqueue(
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        category: AgentNotifyCategory?,
        pending: Bool,
        soundContext: NotificationSoundOverrideContext? = nil,
        approvalID: AgentApprovalCorrelationID? = nil,
        approvalIDIsDerived: Bool = false,
        approvalSource: String? = nil,
        agentKind: String? = nil,
        isSubagent: Bool? = nil,
        correlationKey: String? = nil,
        sessionId: String? = nil,
        coalesces: Bool = false
    ) -> Bool {
        guard allows(category: category, pending: pending) else { return false }
        if category == .needsPermission, let approvalID {
            TerminalMutationBus.shared.enqueueAgentApprovalNotification(
                tabId: workspaceID,
                surfaceId: surfaceID,
                title: title,
                subtitle: subtitle,
                body: body,
                approvalID: approvalID,
                approvalIDIsDerived: approvalIDIsDerived,
                approvalSource: approvalSource,
                agent: Self.agentContext(
                    category: category,
                    pending: pending,
                    agentKind: agentKind,
                    isSubagent: isSubagent,
                    sessionId: sessionId
                ),
                producerCorrelationKey: correlationKey
            )
            return true
        }
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            replyShape: TerminalNotificationReplyShape.forAgentCategory(wire: category?.rawValue),
            agent: Self.agentContext(
                category: category,
                pending: pending,
                agentKind: agentKind,
                isSubagent: isSubagent,
                sessionId: sessionId
            ),
            soundContext: soundContext,
            correlationKey: correlationKey,
            coalesces: coalesces
        )
        return true
    }

    func allows(category: AgentNotifyCategory?, pending: Bool) -> Bool {
        guard let category else { return true }
        return agentNotificationShouldDeliver(category: category, pending: pending,
            permissionEnabled: permissionEnabled, turnMode: turnMode, idleEnabled: idleEnabled)
    }

    /// Builds the hook-facing agent context, or `nil` for untagged legacy
    /// notifications so their hook input stays byte-identical to before.
    static func agentContext(
        category: AgentNotifyCategory?,
        pending: Bool,
        agentKind: String?,
        isSubagent: Bool?,
        sessionId: String? = nil
    ) -> TerminalNotificationPolicyAgentContext? {
        guard category != nil || agentKind != nil || isSubagent != nil else {
            return nil
        }
        return TerminalNotificationPolicyAgentContext(
            kind: agentKind,
            category: category?.rawValue,
            pending: category == nil ? nil : pending,
            isSubagent: isSubagent,
            sessionId: sessionId
        )
    }
}
