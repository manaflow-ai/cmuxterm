import AppKit
import GhosttyKit

extension GhosttyNSView {
    func addReadAloudMenuItems(to menu: NSMenu, surface: ghostty_surface_t) {
        guard let presentation = AppDelegate.shared?.readAloudPresentation else { return }
        if let text = readSelectionSnapshot(surface: surface)?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.readAloud", defaultValue: "Read Aloud"),
                action: #selector(readSelectedTextAloud(_:)),
                keyEquivalent: ""
            )
            item.target = self
            // Preserve precisely the explicit selection at menu-open, without using the clipboard.
            item.representedObject = text
        }
        if presentation.isSpeaking {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.stopSpeaking", defaultValue: "Stop Speaking"),
                action: #selector(stopReadingAloud(_:)),
                keyEquivalent: ""
            )
            item.target = self
        }
        let settings = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.readAloudSettings", defaultValue: "Read Aloud Settings…"),
            action: #selector(showReadAloudSettings(_:)),
            keyEquivalent: ""
        )
        settings.target = self
    }

    @objc private func readSelectedTextAloud(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        AppDelegate.shared?.readAloudPresentation.read(text)
    }

    @objc private func stopReadingAloud(_ sender: Any?) {
        AppDelegate.shared?.readAloudPresentation.stop()
    }

    @objc private func showReadAloudSettings(_ sender: Any?) {
        AppDelegate.shared?.readAloudPresentation.showSettings()
    }
}
