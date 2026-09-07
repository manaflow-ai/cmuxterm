public import CoreGraphics
public import Foundation

/// Plans where a **new** unpinned root workspace should be inserted in the sidebar.
///
/// This is intentionally separate from internal workspace reorder planning.
/// Reorder math answers "where should an existing workspace move?"; this planner
/// answers "at what index should a brand-new workspace be inserted?"
///
/// Geometry reuses ``SidebarDropPlanner``'s new-workspace insertion bands
/// (edge/gap → insert, row center → reject). Callers must supply **root-level**
/// targets only so grouped children / group headers are not treated as legal
/// v1 destinations.
public struct ExternalWorkspaceInsertionPlanner: Sendable {
    /// One root-level sidebar row that can host an external directory insertion.
    public struct RootTarget: Equatable, Sendable {
        /// Workspace identity for the row (never a filesystem path).
        public let workspaceId: UUID
        /// Whether the row sits in the leading pinned segment.
        public let isPinned: Bool
        /// Row frame in the drop overlay's coordinate space.
        public let frame: CGRect

        /// Creates a root-level insertion target.
        ///
        /// - Parameters:
        ///   - workspaceId: Workspace UUID for the row.
        ///   - isPinned: Whether the row is pinned.
        ///   - frame: Row frame in drop coordinates.
        public init(workspaceId: UUID, isPinned: Bool, frame: CGRect) {
            self.workspaceId = workspaceId
            self.isPinned = isPinned
            self.frame = frame
        }
    }

    /// Insertion plan for a new unpinned workspace.
    public struct Plan: Equatable, Sendable {
        /// Index into the provided `rootTargets` / matching top-level order at
        /// which the new workspace should be inserted. Already clamped so an
        /// unpinned workspace cannot land inside the pinned prefix.
        public let insertionIndex: Int
        /// Existing-style sidebar insertion indicator to render.
        public let indicator: SidebarDropIndicator

        /// Creates an external insertion plan.
        ///
        /// - Parameters:
        ///   - insertionIndex: Clamped insertion index for the new workspace.
        ///   - indicator: Drop indicator matching that index.
        public init(insertionIndex: Int, indicator: SidebarDropIndicator) {
            self.insertionIndex = insertionIndex
            self.indicator = indicator
        }
    }

    /// Creates an external new-workspace insertion planner.
    public init() {}

    /// Resolves a pointer location into a new-workspace insertion plan.
    ///
    /// - Parameters:
    ///   - point: Pointer location in the same coordinate space as `rootTargets`.
    ///   - rootTargets: Ordered root-level rows only (no group children / headers).
    /// - Returns: A plan when the pointer is over an insertion band or gap;
    ///   `nil` when targets are empty, or when the pointer is over a row center
    ///   (rejected so we never imply opening an existing workspace).
    public func plan(
        point: CGPoint,
        rootTargets: [RootTarget]
    ) -> Plan? {
        guard !rootTargets.isEmpty else {
            return nil
        }

        let dropTargets = rootTargets.map {
            SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: $0.workspaceId,
                isPinned: $0.isPinned,
                frame: $0.frame
            )
        }
        guard let action = SidebarDropPlanner().workspaceAction(
            for: point,
            targets: dropTargets
        ) else {
            return nil
        }

        // Mid-row "drop onto existing workspace" is bonsplit semantics, not
        // Finder directory creation. Reject so we never imply reuse/dedupe.
        guard case .newWorkspace(let insertionIndex, let indicator) = action else {
            return nil
        }
        return Plan(insertionIndex: insertionIndex, indicator: indicator)
    }

    /// Insertion plan when the sidebar has no root rows yet.
    ///
    /// - Returns: Append-at-zero with an end-of-list indicator.
    public func planForEmptySidebar() -> Plan {
        Plan(
            insertionIndex: 0,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
        )
    }

    /// Maps a top-level insertion slot to a raw `tabs` array index.
    ///
    /// - Parameters:
    ///   - slot: Index into `topLevelIds` (or `topLevelIds.count` to append).
    ///   - topLevelIds: Root-level workspace ids in sidebar order.
    ///   - tabIds: Full workspace storage order (`TabManager.tabs` ids).
    /// - Returns: Index suitable for `insertionIndexOverride` on workspace creation.
    public func rawTabInsertionIndex(
        forTopLevelSlot slot: Int,
        topLevelIds: [UUID],
        tabIds: [UUID]
    ) -> Int {
        let clampedSlot = max(0, min(slot, topLevelIds.count))
        guard clampedSlot < topLevelIds.count else {
            return tabIds.count
        }
        let topLevelId = topLevelIds[clampedSlot]
        if let liveIndex = tabIds.firstIndex(of: topLevelId) {
            return liveIndex
        }
        for nextId in topLevelIds.dropFirst(clampedSlot + 1) {
            if let nextIndex = tabIds.firstIndex(of: nextId) {
                return nextIndex
            }
        }
        return tabIds.count
    }
}
