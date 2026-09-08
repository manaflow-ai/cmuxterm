extension TabManager {
    @discardableResult
    func toggleFocusedSessionOutline() -> Bool {
        selectedTerminalPanel?.sessionOutlineModel.togglePresentation() ?? false
    }
}
