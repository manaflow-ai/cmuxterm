public import Foundation

/// Projects a preferred workspace order onto sidebar group and pin invariants.
///
/// A group moves as one block using its highest-ranked member. Members remain
/// ordered by the preference. Pinned groups and ungrouped pinned workspaces
/// remain ahead of the unpinned tier. Unknown and duplicate preferred ids are
/// ignored, and omitted workspaces retain their persisted relative order.
public struct SidebarWorkspaceOrderPlanner: Sendable {
    /// Creates the stateless planner.
    public init() {}

    /// Returns every current workspace id in its safe display order.
    public func orderedWorkspaceIds(
        preferredWorkspaceIds: [UUID],
        current: [SidebarWorkspaceOrderSnapshot],
        groups: [SidebarWorkspaceOrderGroupSnapshot]
    ) -> [UUID] {
        guard current.count > 1 else { return current.map(\.id) }

        let knownIds = Set(current.map(\.id))
        var seen = Set<UUID>()
        var completePreference = preferredWorkspaceIds.filter {
            knownIds.contains($0) && seen.insert($0).inserted
        }
        completePreference.append(contentsOf: current.map(\.id).filter { seen.insert($0).inserted })

        let rankById = Dictionary(
            uniqueKeysWithValues: completePreference.enumerated().map { ($0.element, $0.offset) }
        )
        let currentIndexById = Dictionary(
            uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) }
        )
        let groupById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })

        struct Block {
            let workspaceIds: [UUID]
            let isPinned: Bool
            let rank: Int
            let currentIndex: Int
        }

        var membersByGroupId: [UUID: [SidebarWorkspaceOrderSnapshot]] = [:]
        for workspace in current {
            guard let groupId = workspace.groupId, groupById[groupId] != nil else { continue }
            membersByGroupId[groupId, default: []].append(workspace)
        }
        var emittedGroupIds = Set<UUID>()
        var blocks: [Block] = []
        blocks.reserveCapacity(current.count)

        for workspace in current {
            if let groupId = workspace.groupId,
               let group = groupById[groupId],
               emittedGroupIds.insert(groupId).inserted {
                let members = (membersByGroupId[groupId] ?? [])
                    .sorted {
                        let lhsRank = rankById[$0.id] ?? Int.max
                        let rhsRank = rankById[$1.id] ?? Int.max
                        if lhsRank != rhsRank { return lhsRank < rhsRank }
                        return (currentIndexById[$0.id] ?? Int.max) <
                            (currentIndexById[$1.id] ?? Int.max)
                    }
                let ids = members.map(\.id)
                blocks.append(Block(
                    workspaceIds: ids,
                    isPinned: group.isPinned,
                    rank: ids.compactMap { rankById[$0] }.min() ?? Int.max,
                    currentIndex: ids.compactMap { currentIndexById[$0] }.min() ?? Int.max
                ))
            } else if workspace.groupId.flatMap({ groupById[$0] }) == nil {
                blocks.append(Block(
                    workspaceIds: [workspace.id],
                    isPinned: workspace.isPinned,
                    rank: rankById[workspace.id] ?? Int.max,
                    currentIndex: currentIndexById[workspace.id] ?? Int.max
                ))
            }
        }

        return blocks.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.currentIndex < rhs.currentIndex
        }.flatMap(\.workspaceIds)
    }
}
