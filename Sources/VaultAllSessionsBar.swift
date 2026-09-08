import SwiftUI

/// Chrome row shown for every Vault grouping: session search and view density.
/// Mounted directly by
/// `SessionIndexView` above the table boundary, mirroring the existing control
/// bar (safe to observe the store here — never inside table rows).
struct VaultAllSessionsBar: View {
    @Binding var searchText: String
    /// Shared row-density preference. Default view shows repository/branch
    /// details; compact view hides that second line in every Vault grouping.
    @Binding var isCompactView: Bool
    /// Enter — peek the top search result.
    let onPeekTopResult: () -> Void
    /// Cmd+Enter — resume the top search result.
    let onResumeTopResult: () -> Void

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    private var searchFieldHeight: CGFloat {
        _ = globalFontPercent
        return SidebarSearchField.visibleHeight
    }

    private var searchBarHeight: CGFloat {
        max(RightSidebarChromeMetrics.secondaryBarHeight, searchFieldHeight + 6)
    }

    var body: some View {
        HStack(spacing: 0) {
            searchField
            overflowMenu
        }
        // Keep Vault's compact toolbar spacing around the shared field.
        .padding(.leading, 4)
        .padding(.trailing, 0)
        .padding(.vertical, 3)
        .frame(height: searchBarHeight)
    }

    private var searchField: some View {
        SidebarSearchFieldView(
            text: $searchText,
            placeholder: String(localized: "sessionIndex.allSessions.searchPlaceholder",
                                defaultValue: "Search sessions…"),
            accessibilityIdentifier: "VaultAllSessionsSearchField",
            onSubmit: onPeekTopResult,
            onCommandSubmit: onResumeTopResult
        )
        .frame(height: searchFieldHeight)
        // The field owns the flexible width; the utility controls keep their
        // standard 20-point targets at the trailing edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .titlebarInteractiveControl()
    }

    private var overflowMenu: some View {
        Menu {
            Picker(
                String(localized: "sessionIndex.view.title", defaultValue: "Session view"),
                selection: $isCompactView
            ) {
                Text(String(localized: "sessionIndex.view.default", defaultValue: "Default view"))
                    .tag(false)
                Text(String(localized: "sessionIndex.view.compact", defaultValue: "Compact view"))
                    .tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Text("⋮")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.72))
                .frame(width: 24, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .contentShape(Rectangle())
        .help(String(localized: "sessionIndex.view.tooltip", defaultValue: "Choose session view"))
        .accessibilityLabel(Text(String(localized: "sessionIndex.view.title", defaultValue: "Session view")))
        .accessibilityHint(Text(String(localized: "sessionIndex.view.tooltip", defaultValue: "Choose session view")))
        .accessibilityValue(viewSelectionLabel)
        .accessibilityIdentifier("VaultSessionOptionsMenu")
        .frame(width: 24, height: 28)
        .layoutPriority(2)
        .titlebarInteractiveControl()
    }

    private var viewSelectionLabel: String {
        if isCompactView {
            return String(localized: "sessionIndex.view.compact", defaultValue: "Compact view")
        }
        return String(localized: "sessionIndex.view.default", defaultValue: "Default view")
    }

}
