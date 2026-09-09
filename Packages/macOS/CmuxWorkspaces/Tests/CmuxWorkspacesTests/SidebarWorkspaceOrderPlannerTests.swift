import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("SidebarWorkspaceOrderPlanner")
struct SidebarWorkspaceOrderPlannerTests {
    private let planner = SidebarWorkspaceOrderPlanner()

    @Test func honorsPreferredOrderAndAppendsOmittedWorkspaces() {
        let ids = (0..<4).map { _ in UUID() }
        let current = ids.map {
            SidebarWorkspaceOrderSnapshot(id: $0, isPinned: false, groupId: nil)
        }

        let result = planner.orderedWorkspaceIds(
            preferredWorkspaceIds: [UUID(), ids[2], ids[2], ids[0]],
            current: current,
            groups: []
        )

        #expect(result == [ids[2], ids[0], ids[1], ids[3]])
    }

    @Test func keepsGroupsContiguousUsingTheHighestRankedMember() {
        let a = UUID()
        let groupedA = UUID()
        let groupedB = UUID()
        let c = UUID()
        let groupId = UUID()
        let current = [
            SidebarWorkspaceOrderSnapshot(id: a, isPinned: false, groupId: nil),
            SidebarWorkspaceOrderSnapshot(id: groupedA, isPinned: false, groupId: groupId),
            SidebarWorkspaceOrderSnapshot(id: groupedB, isPinned: false, groupId: groupId),
            SidebarWorkspaceOrderSnapshot(id: c, isPinned: false, groupId: nil),
        ]

        let result = planner.orderedWorkspaceIds(
            preferredWorkspaceIds: [groupedB, c, a, groupedA],
            current: current,
            groups: [SidebarWorkspaceOrderGroupSnapshot(id: groupId, isPinned: false)]
        )

        #expect(result == [groupedB, groupedA, c, a])
    }

    @Test func preservesPinnedTierForWorkspacesAndGroups() {
        let pinnedWorkspace = UUID()
        let pinnedGroupMember = UUID()
        let unpinnedWorkspace = UUID()
        let pinnedGroupId = UUID()
        let current = [
            SidebarWorkspaceOrderSnapshot(
                id: pinnedWorkspace,
                isPinned: true,
                groupId: nil
            ),
            SidebarWorkspaceOrderSnapshot(
                id: pinnedGroupMember,
                isPinned: false,
                groupId: pinnedGroupId
            ),
            SidebarWorkspaceOrderSnapshot(
                id: unpinnedWorkspace,
                isPinned: false,
                groupId: nil
            ),
        ]

        let result = planner.orderedWorkspaceIds(
            preferredWorkspaceIds: [unpinnedWorkspace, pinnedGroupMember, pinnedWorkspace],
            current: current,
            groups: [SidebarWorkspaceOrderGroupSnapshot(id: pinnedGroupId, isPinned: true)]
        )

        #expect(result == [pinnedGroupMember, pinnedWorkspace, unpinnedWorkspace])
    }
}
