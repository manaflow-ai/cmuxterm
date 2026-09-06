import AppKit

extension AppDelegate {
    /// The View menu route for the blueprint drawer: resolves the tab manager
    /// of the preferred (key/main) window and toggles the focused terminal's
    /// blueprint through the shared `TabManager.performBlueprintAction` path.
    @discardableResult
    func performBlueprintMenuToggle(preferredWindow: NSWindow? = nil) -> Bool {
        guard TerminalBlueprintFeature.isEnabled() else { return false }
        let manager = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)?.tabManager ?? tabManager
        return manager?.performBlueprintAction(.toggle) ?? false
    }
}
