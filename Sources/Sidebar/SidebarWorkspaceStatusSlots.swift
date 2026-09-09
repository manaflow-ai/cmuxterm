import SwiftUI

enum SidebarWorkspaceLoadingTooltip {
    static func text(count: Int) -> String {
        SidebarWorkspaceRowLocalizedStrings.loadingTooltip(count: count)
    }
}
