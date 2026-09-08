import AppKit
import CmuxPanes

extension AppDelegate {
    /// Fixed step used by the two focused-pane growth actions.
    private static let paneGrowthStep: UInt16 = 20
    private static let paneGrowthShortcutActions: [KeyboardShortcutSettings.Action] = [
        .growPaneWidth,
        .growPaneHeight,
    ]

    /// Routes configured focused-pane growth shortcuts.
    func handlePaneGrowthShortcut(event: NSEvent) -> Bool {
        let actions = Self.paneGrowthShortcutActions
        guard let action = preferredMatchingShortcutAction(event: event, actions: actions),
              !explicitShortcutOverrideShouldPreemptImplicitDefault(
                event: event,
                matchedAction: action,
                actionFamily: actions
              ) else {
            return false
        }

        let axis: PaneAxis = action == .growPaneHeight ? .height : .width
        if performFocusedDockShortcut(
            .growPane(axis, amountPixels: Self.paneGrowthStep),
            action: action,
            event: event
        ) {
            return true
        }

        let manager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: manager) {
            return true
        }
        if manager?.growSelectedPane(axis: axis, amountPixels: Self.paneGrowthStep) != true {
            NSSound.beep()
        }
#if DEBUG
        cmuxDebugLog("shortcut.action name=\(action.rawValue) axis=\(axis)")
#endif
        return true
    }
}
