import Foundation

/// The policy that orders workspace rows in the left sidebar.
public enum SidebarWorkspaceOrder: String, CaseIterable, Hashable, Sendable, SettingCodable {
    /// Preserve the existing behavior that moves a workspace toward the top
    /// when it receives a notification.
    case notificationRecency
    /// Display older workspaces before newer workspaces.
    case creation
    /// Display the persisted order controlled by drag and reorder commands.
    case manual
    /// Display the order returned by `~/.config/cmux/sidebar-order.js`.
    case custom

    /// Whether dragging can directly change the order currently on screen.
    public var allowsManualReordering: Bool {
        switch self {
        case .notificationRecency, .manual:
            true
        case .creation, .custom:
            false
        }
    }

    /// Decodes both the current string representation and the legacy Boolean
    /// stored by `app.reorderOnNotification`.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        if let raw = raw as? String {
            return Self(rawValue: raw)
        }
        if let raw = raw as? Bool {
            return raw ? .notificationRecency : .manual
        }
        return nil
    }

    /// Encodes the current string representation for `UserDefaults`.
    public func encodeForUserDefaults() -> Any {
        rawValue
    }

    /// Decodes the string representation used by `cmux.json`.
    public static func decodeFromJSON(_ raw: Any?) -> Self? {
        guard let raw = raw as? String else { return nil }
        return Self(rawValue: raw)
    }

    /// Encodes the string representation used by `cmux.json`.
    public func encodeForJSON() -> Any {
        rawValue
    }
}
