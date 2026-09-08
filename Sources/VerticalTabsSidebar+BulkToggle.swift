import SwiftUI

extension VerticalTabsSidebar {
    @ViewBuilder
    func workspaceGroupBulkToggleOverlay(renderContext: WorkspaceListRenderContext) -> some View {
        if isPresented, !renderContext.workspaceGroups.isEmpty {
            SidebarWorkspaceGroupBulkToggle(
                allGroupsCollapsed: renderContext.workspaceGroups.allSatisfy(\.isCollapsed),
                onCollapseAll: { [weak tabManager] in tabManager?.collapseAllWorkspaceGroups() },
                onExpandAll: { [weak tabManager] in tabManager?.expandAllWorkspaceGroups() }
            )
            .padding(.top, 4)
            .padding(.trailing, 6)
        }
    }
}
