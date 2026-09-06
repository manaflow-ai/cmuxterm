import AppKit
import SwiftUI

/// The collapsible blueprint drawer rendered below a terminal surface.
///
/// Layout: an optional resize handle on the top edge, a 30pt header bar, and
/// the Excalidraw canvas while expanded. The drawer's height comes from the
/// state's layout and the pane height the parent measured.
struct TerminalBlueprintDrawerView: View {
    let state: TerminalBlueprintState
    let session: TerminalBlueprintWebSession
    let appearance: PanelAppearance
    let containerHeight: CGFloat
    let onRequestPanelFocus: () -> Void

    @State private var dragStartHeight: CGFloat?

    private var drawerHeight: CGFloat {
        CGFloat(state.layout.drawerHeight(containerHeight: Double(containerHeight)))
    }

    private var isDark: Bool {
        MarkdownWebTheme.resolve(backgroundColor: appearance.backgroundColor).isDark
    }

    private var foreground: Color {
        Color(nsColor: appearance.foregroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.isExpanded {
                resizeHandle
            } else {
                Rectangle()
                    .fill(appearance.dividerColor)
                    .frame(height: 1)
            }
            header
            if state.isExpanded {
                ZStack(alignment: .top) {
                    TerminalBlueprintWebRenderer(
                        state: state,
                        session: session,
                        isDark: isDark,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
                        errorBanner(errorMessage)
                    }
                }
            }
        }
        .frame(height: drawerHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TerminalBlueprintDrawer")
    }

    private var resizeHandle: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(appearance.dividerColor)
                .frame(height: 1)
        }
        .frame(height: 7)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? drawerHeight
                    if dragStartHeight == nil {
                        dragStartHeight = start
                    }
                    guard containerHeight > 0 else { return }
                    let proposed = start - value.translation.height
                    state.setSplitFraction(Double(proposed / containerHeight))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .accessibilityIdentifier("TerminalBlueprintResizeHandle")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 11, weight: .medium))
            Text(String(localized: "blueprint.header.title", defaultValue: "Blueprint"))
                .font(.system(size: 11, weight: .semibold))
            if state.hasUnseenAgentUpdate {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text(String(localized: "blueprint.header.updatedByAgent", defaultValue: "Updated by agent"))
                        .font(.system(size: 10))
                }
                .foregroundStyle(foreground.opacity(0.75))
            }
            Spacer(minLength: 8)
            headerButton(
                systemName: state.isExpanded ? "chevron.down" : "chevron.up",
                help: state.isExpanded
                    ? String(localized: "blueprint.header.collapse", defaultValue: "Collapse Blueprint")
                    : String(localized: "blueprint.header.expand", defaultValue: "Expand Blueprint"),
                identifier: "TerminalBlueprintCollapseButton"
            ) {
                state.perform(state.isExpanded ? .collapse : .expand)
            }
            headerButton(
                systemName: state.layout.isEnlarged
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: state.layout.isEnlarged
                    ? String(localized: "blueprint.header.restore", defaultValue: "Restore Blueprint Size")
                    : String(localized: "blueprint.header.enlarge", defaultValue: "Enlarge Blueprint"),
                identifier: "TerminalBlueprintEnlargeButton"
            ) {
                state.perform(state.layout.isEnlarged ? .restore : .enlarge)
            }
            Menu {
                Button(String(localized: "blueprint.menu.zoomToFit", defaultValue: "Zoom to Fit")) {
                    state.perform(.zoomToFit)
                }
                .disabled(!state.isExpanded)
                Button(String(localized: "blueprint.menu.clear", defaultValue: "Clear Canvas")) {
                    state.perform(.clear)
                }
                Divider()
                Button(String(localized: "blueprint.menu.close", defaultValue: "Hide Blueprint")) {
                    state.perform(.close)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "blueprint.header.more", defaultValue: "More Blueprint Actions"))
            .accessibilityIdentifier("TerminalBlueprintMoreMenu")
            headerButton(
                systemName: "xmark",
                help: String(localized: "blueprint.menu.close", defaultValue: "Hide Blueprint"),
                identifier: "TerminalBlueprintCloseButton"
            ) {
                state.perform(.close)
            }
        }
        .foregroundStyle(foreground.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: CGFloat(TerminalBlueprintLayout.headerHeight))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            state.perform(state.isExpanded ? .collapse : .expand)
        }
    }

    private func headerButton(
        systemName: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(identifier)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.85))
            .accessibilityIdentifier("TerminalBlueprintErrorBanner")
    }
}
