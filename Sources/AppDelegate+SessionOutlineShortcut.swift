import AppKit

extension AppDelegate {
    func handleSessionOutlineShortcut(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleSessionOutline) else {
            return nil
        }
        if performFocusedDockShortcut(
            .toggleSessionOutline,
            action: .toggleSessionOutline,
            event: event
        ) {
            return true
        }
        let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        let handled = routedManager?.toggleFocusedSessionOutline() ?? false
#if DEBUG
        cmuxDebugLog(
            "shortcut.action name=toggleSessionOutline handled=\(handled ? 1 : 0) " +
            "\(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        return handled
    }
}
