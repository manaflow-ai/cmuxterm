import CmuxControlSocket
import Foundation

extension TerminalController {
    func controlSubmitWorkspacePrompt(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        message: String?
    ) -> ControlWorkspacePromptSubmitResolution {
        guard let tabManager = (AppDelegate.shared?.tabManagerFor(tabId: workspaceID))
            ?? resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        guard let outcome = tabManager.handlePromptSubmit(
            workspaceId: workspaceID,
            message: message,
            surfaceId: routing.surfaceID,
            iMessageModeEnabled: iMessageModeEnabled
        ) else {
            return .notFound
        }
        let preview = tabManager.tabs.first(where: { $0.id == workspaceID })?.latestSubmittedMessage
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(
            windowID: windowId,
            iMessageModeEnabled: iMessageModeEnabled,
            messageRecorded: outcome.messageRecorded,
            reordered: outcome.reordered,
            index: outcome.index,
            messagePreview: preview
        )
    }
}
