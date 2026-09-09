public import Foundation

/// The ordering fields for one workspace in the default sidebar.
public struct SidebarWorkspaceOrderSnapshot: Equatable, Sendable {
    /// Stable workspace identity.
    public let id: UUID
    /// Whether an ungrouped workspace belongs in the pinned tier.
    public let isPinned: Bool
    /// Effective renderable group membership, when present.
    public let groupId: UUID?

    /// Creates an immutable ordering snapshot.
    public init(id: UUID, isPinned: Bool, groupId: UUID?) {
        self.id = id
        self.isPinned = isPinned
        self.groupId = groupId
    }
}

/// The ordering fields for one workspace group in the default sidebar.
public struct SidebarWorkspaceOrderGroupSnapshot: Equatable, Sendable {
    /// Stable group identity.
    public let id: UUID
    /// Whether the whole group belongs in the pinned tier.
    public let isPinned: Bool

    /// Creates an immutable group ordering snapshot.
    public init(id: UUID, isPinned: Bool) {
        self.id = id
        self.isPinned = isPinned
    }
}
