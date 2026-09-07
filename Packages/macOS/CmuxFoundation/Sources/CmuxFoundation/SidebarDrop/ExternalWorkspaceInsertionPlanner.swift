public import CoreGraphics
public import Foundation

/// Plans where a **new** unpinned root workspace should be inserted in the sidebar.
///
/// Geometry uses **visible** root rows. ``Plan/insertionIndex`` is always a slot
/// in the **complete** top-level ungrouped order (not the visible-only array).
public struct ExternalWorkspaceInsertionPlanner: Sendable {
    /// One visible root-level sidebar row used for pointer geometry.
    public struct RootTarget: Equatable, Sendable {
        public let workspaceId: UUID
        public let isPinned: Bool
        public let frame: CGRect

        public init(workspaceId: UUID, isPinned: Bool, frame: CGRect) {
            self.workspaceId = workspaceId
            self.isPinned = isPinned
            self.frame = frame
        }
    }

    /// Insertion plan for a new unpinned workspace.
    public struct Plan: Equatable, Sendable {
        /// Index into the complete top-level ungrouped order, or `count` to append.
        /// Clamped so an unpinned workspace cannot land inside the pinned prefix.
        public let insertionIndex: Int
        /// Existing-style sidebar insertion indicator to render.
        public let indicator: SidebarDropIndicator

        public init(insertionIndex: Int, indicator: SidebarDropIndicator) {
            self.insertionIndex = insertionIndex
            self.indicator = indicator
        }
    }

    public init() {}

    /// Resolves a pointer location into a new-workspace insertion plan.
    ///
    /// - Parameters:
    ///   - point: Pointer in the same coordinate space as `visibleRootTargets`.
    ///   - visibleRootTargets: On-screen root rows for geometry / indicator.
    ///   - completeTopLevelIds: Full ungrouped root order for the commit slot.
    ///   - completePinnedCount: Leading pinned prefix length in that complete order.
    public func plan(
        point: CGPoint,
        visibleRootTargets: [RootTarget],
        completeTopLevelIds: [UUID],
        completePinnedCount: Int
    ) -> Plan? {
        guard !visibleRootTargets.isEmpty else {
            return nil
        }

        let dropTargets = visibleRootTargets.map {
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

        guard case .newWorkspace(let visibleSlot, let visibleIndicator) = action else {
            return nil
        }

        let visibleIds = visibleRootTargets.map(\.workspaceId)
        let completeSlot = completeTopLevelSlot(
            fromVisibleSlot: visibleSlot,
            visibleIds: visibleIds,
            completeTopLevelIds: completeTopLevelIds
        )
        let clampedSlot = max(
            0,
            min(
                max(completeSlot, max(0, completePinnedCount)),
                completeTopLevelIds.count
            )
        )
        let indicator = remappedIndicator(
            visibleIndicator: visibleIndicator,
            completeSlot: clampedSlot,
            completeTopLevelIds: completeTopLevelIds,
            visibleRootTargets: visibleRootTargets
        )
        return Plan(insertionIndex: clampedSlot, indicator: indicator)
    }

    /// Convenience when every root row is visible (unit tests / short lists).
    public func plan(
        point: CGPoint,
        rootTargets: [RootTarget]
    ) -> Plan? {
        let pinnedCount = rootTargets.prefix(while: \.isPinned).count
        return plan(
            point: point,
            visibleRootTargets: rootTargets,
            completeTopLevelIds: rootTargets.map(\.workspaceId),
            completePinnedCount: pinnedCount
        )
    }

    /// Insertion plan when the sidebar has no root rows yet.
    public func planForEmptySidebar() -> Plan {
        Plan(
            insertionIndex: 0,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
        )
    }

    /// Maps a visible-array insertion slot onto the complete top-level order.
    public func completeTopLevelSlot(
        fromVisibleSlot visibleSlot: Int,
        visibleIds: [UUID],
        completeTopLevelIds: [UUID]
    ) -> Int {
        let clampedVisible = max(0, min(visibleSlot, visibleIds.count))
        if clampedVisible < visibleIds.count {
            let anchorId = visibleIds[clampedVisible]
            return completeTopLevelIds.firstIndex(of: anchorId) ?? completeTopLevelIds.count
        }
        guard let lastVisibleId = visibleIds.last,
              let lastCompleteIndex = completeTopLevelIds.firstIndex(of: lastVisibleId) else {
            return completeTopLevelIds.count
        }
        return lastCompleteIndex + 1
    }

    /// Maps a top-level insertion slot to a raw `tabs` array index.
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

    /// Filters raw sidebar row descriptors to ungrouped roots before pinned lookup.
    ///
    /// Group headers reuse an anchor ``workspaceId`` that can also appear on a
    /// grouped member. Building `Dictionary(uniqueKeysWithValues:)` from raw
    /// rows can therefore trap; callers must filter first.
    public static func eligibleUngroupedRoots(
        from rows: [(workspaceId: UUID, isPinned: Bool, isGroupHeader: Bool, groupId: UUID?)]
    ) -> [(workspaceId: UUID, isPinned: Bool)] {
        rows.compactMap { row in
            guard !row.isGroupHeader, row.groupId == nil else { return nil }
            return (row.workspaceId, row.isPinned)
        }
    }

    /// Pinned flags for eligible ungrouped roots. Uses assignment (last write
    /// wins) rather than `uniqueKeysWithValues`, so duplicate ids cannot trap.
    public static func pinnedFlagsByWorkspaceId(
        fromEligibleUngroupedRoots roots: [(workspaceId: UUID, isPinned: Bool)]
    ) -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        result.reserveCapacity(roots.count)
        for root in roots {
            result[root.workspaceId] = root.isPinned
        }
        return result
    }

    private func remappedIndicator(
        visibleIndicator: SidebarDropIndicator,
        completeSlot: Int,
        completeTopLevelIds: [UUID],
        visibleRootTargets: [RootTarget]
    ) -> SidebarDropIndicator {
        if let tabId = visibleIndicator.tabId,
           let completeIndex = completeTopLevelIds.firstIndex(of: tabId) {
            let impliedSlot = visibleIndicator.edge == .bottom ? completeIndex + 1 : completeIndex
            if impliedSlot == completeSlot {
                return visibleIndicator
            }
        }

        if completeSlot >= completeTopLevelIds.count {
            if let lastVisible = visibleRootTargets.last {
                return SidebarDropIndicator(tabId: lastVisible.workspaceId, edge: .bottom)
            }
            return SidebarDropIndicator(tabId: nil, edge: .bottom)
        }

        let anchorId = completeTopLevelIds[completeSlot]
        if visibleRootTargets.contains(where: { $0.workspaceId == anchorId }) {
            return SidebarDropIndicator(tabId: anchorId, edge: .top)
        }
        if let lastVisible = visibleRootTargets.last,
           let lastComplete = completeTopLevelIds.firstIndex(of: lastVisible.workspaceId),
           completeSlot > lastComplete {
            return SidebarDropIndicator(tabId: lastVisible.workspaceId, edge: .bottom)
        }
        if let firstVisible = visibleRootTargets.first {
            return SidebarDropIndicator(tabId: firstVisible.workspaceId, edge: .top)
        }
        return SidebarDropIndicator(tabId: anchorId, edge: .top)
    }
}
