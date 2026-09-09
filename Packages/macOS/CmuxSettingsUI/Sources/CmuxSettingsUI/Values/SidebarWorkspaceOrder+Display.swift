import CmuxSettings
import Foundation

extension SidebarWorkspaceOrder {
    static var uiCases: [SidebarWorkspaceOrder] {
        [.notificationRecency, .creation, .manual, .custom]
    }

    var displayName: String {
        switch self {
        case .notificationRecency:
            return String(
                localized: "settings.app.reorderOnNotification",
                defaultValue: "Reorder on Notification"
            )
        case .creation:
            return String(
                localized: "sidebar.workspaceOrder.creation.name",
                defaultValue: "Order of Creation"
            )
        case .manual:
            return String(
                localized: "sidebar.workspaceOrder.manual.name",
                defaultValue: "Manual Order"
            )
        case .custom:
            return String(
                localized: "sidebar.workspaceOrder.custom.name",
                defaultValue: "Custom Function"
            )
        }
    }

    var sidebarDescription: String {
        switch self {
        case .notificationRecency:
            return String(
                localized: "settings.app.reorderOnNotification.subtitle",
                defaultValue: "Move workspaces to the top when they receive a notification. Disable for stable shortcut positions."
            )
        case .creation:
            return String(
                localized: "sidebar.workspaceOrder.creation.description",
                defaultValue: "Keep older workspaces above newer workspaces."
            )
        case .manual:
            return String(
                localized: "sidebar.workspaceOrder.manual.description",
                defaultValue: "Use the saved order controlled by dragging and reorder commands."
            )
        case .custom:
            return String(
                localized: "sidebar.workspaceOrder.custom.description",
                defaultValue: "Run orderWorkspaces in ~/.config/cmux/sidebar-order.js."
            )
        }
    }
}
