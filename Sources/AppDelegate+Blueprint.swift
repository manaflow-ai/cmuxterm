import AppKit

extension AppDelegate {
    /// Mirrors the Blueprint beta toggle to the file the agent wrappers read,
    /// now and on every defaults change (the Settings toggle writes defaults).
    func startBlueprintLiveSettingSync() {
        guard !SessionRestorePolicy.isRunningUnderAutomatedTests() else { return }
        TerminalBlueprintFeature.syncLiveSettingFile()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            TerminalBlueprintFeature.syncLiveSettingFile()
        }
    }

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
