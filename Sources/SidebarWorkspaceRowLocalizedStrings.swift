import CmuxSidebar
import CmuxWorkspaces
import Foundation

enum SidebarWorkspaceRowLocalizedStrings {
    static let closeWorkspaceTooltip = String(
        localized: "sidebar.closeWorkspace.tooltip",
        defaultValue: "Close Workspace"
    )
    static let pinnedWorkspaceProtectedTooltip = String(
        localized: "sidebar.pinnedWorkspaceProtected.tooltip",
        defaultValue: "Pinned workspace. Closing requires confirmation."
    )
    static let accessibilityHint = String(
        localized: "sidebar.workspace.accessibilityHint",
        defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."
    )
    static let moveUpAction = String(
        localized: "sidebar.workspace.moveUpAction",
        defaultValue: "Move Up"
    )
    static let moveDownAction = String(
        localized: "sidebar.workspace.moveDownAction",
        defaultValue: "Move Down"
    )
    static let mutedWorkspaceTooltip = String(
        localized: "sidebar.mutedWorkspace.tooltip",
        defaultValue: "Notifications muted for this workspace"
    )
    static let remoteReconnectButton = String(
        localized: "sidebar.remote.reconnect.button",
        defaultValue: "Reconnect"
    )
    static let remoteReconnectHelpFormat = String(
        localized: "sidebar.remote.reconnect.help",
        defaultValue: "Reconnect to %@"
    )
    static let renameFieldAccessibilityLabel = String(
        localized: "sidebar.workspace.rename.field.accessibilityLabel",
        defaultValue: "Rename workspace"
    )
    static let workspaceNamePlaceholder = String(
        localized: "commandPalette.rename.workspacePlaceholder",
        defaultValue: "Workspace name"
    )
    static let workspacePositionFormat = String(
        localized: "accessibility.workspacePosition",
        defaultValue: "%1$@, workspace %2$lld of %3$lld"
    )
    static let pullRequestTitleFormat = String(
        localized: "sidebar.pullRequest.title",
        defaultValue: "%1$@ #%2$lld"
    )
    static let pullRequestOpenTooltipFormat = String(
        localized: "sidebar.pullRequest.openTooltip",
        defaultValue: "Open %1$@ #%2$lld"
    )
    static let pullRequestStatusOpen = String(
        localized: "sidebar.pullRequest.statusOpen",
        defaultValue: "open"
    )
    static let pullRequestStatusMerged = String(
        localized: "sidebar.pullRequest.statusMerged",
        defaultValue: "merged"
    )
    static let pullRequestStatusClosed = String(
        localized: "sidebar.pullRequest.statusClosed",
        defaultValue: "closed"
    )
    static let loadingOneFormat = String(
        localized: "sidebar.agentActivity.tooltip.one",
        defaultValue: "Loading (1 active task)"
    )
    static let loadingManyFormat = String(
        localized: "sidebar.agentActivity.tooltip.many",
        defaultValue: "Loading (%lld active tasks)"
    )
    static let statusCompactLabelFormat = String(
        localized: "sidebar.status.compactLabel",
        defaultValue: "Status: %@"
    )
    static let statusCompactTooltip = String(
        localized: "sidebar.status.compactTooltip",
        defaultValue: "Change workspace status"
    )
    static let statusTooltipManualFormat = String(
        localized: "sidebar.status.tooltip.manual",
        defaultValue: "%@ — set manually"
    )
    static let statusTooltipInferredFormat = String(
        localized: "sidebar.status.tooltip.inferred",
        defaultValue: "%@ — inferred"
    )
    static let statusTodo = String(
        localized: "sidebar.status.todo",
        defaultValue: "Todo"
    )
    static let statusWorking = String(
        localized: "sidebar.status.working",
        defaultValue: "Working"
    )
    static let statusNeedsAttention = String(
        localized: "sidebar.status.needsAttention",
        defaultValue: "Needs Attention"
    )
    static let statusReview = String(
        localized: "sidebar.status.review",
        defaultValue: "In Review"
    )
    static let statusDone = String(
        localized: "sidebar.status.done",
        defaultValue: "Done"
    )

    static func workspacePosition(title: String, index: Int, count: Int) -> String {
        String.localizedStringWithFormat(
            workspacePositionFormat,
            title,
            Int64(index),
            Int64(count)
        )
    }

    static func remoteReconnectHelp(target: String) -> String {
        String.localizedStringWithFormat(remoteReconnectHelpFormat, target)
    }

    static func pullRequestOpenTooltip(label: String, number: Int) -> String {
        String.localizedStringWithFormat(pullRequestOpenTooltipFormat, label, Int64(number))
    }

    static func pullRequestTitle(label: String, number: Int) -> String {
        String.localizedStringWithFormat(pullRequestTitleFormat, label, Int64(number))
    }

    static func loadingTooltip(count: Int) -> String {
        if count == 1 {
            return loadingOneFormat
        }
        return String.localizedStringWithFormat(loadingManyFormat, Int64(count))
    }

    static func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open:
            return pullRequestStatusOpen
        case .merged:
            return pullRequestStatusMerged
        case .closed:
            return pullRequestStatusClosed
        }
    }

    static func statusDisplayName(_ status: WorkspaceTaskStatus) -> String {
        switch status {
        case .todo:
            return statusTodo
        case .working:
            return statusWorking
        case .needsAttention:
            return statusNeedsAttention
        case .review:
            return statusReview
        case .done:
            return statusDone
        }
    }

    static func statusCompactLabel(_ status: WorkspaceTaskStatus) -> String {
        String.localizedStringWithFormat(statusCompactLabelFormat, statusDisplayName(status))
    }

    static func statusTooltip(status: WorkspaceTaskStatus, hasOverride: Bool) -> String {
        String.localizedStringWithFormat(
            hasOverride ? statusTooltipManualFormat : statusTooltipInferredFormat,
            statusDisplayName(status)
        )
    }
}
