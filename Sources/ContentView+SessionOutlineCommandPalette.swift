import AppKit
import CmuxCommandPalette

extension ContentView {
    static func sessionOutlineCommandPaletteContribution() -> CommandPaletteCommandContribution {
        let subtitle: (CommandPaletteContextSnapshot) -> String = { context in
            let name = context.string(CommandPaletteContextKeys.panelName)
                ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }
        return CommandPaletteCommandContribution(
            commandId: "palette.terminalToggleSessionOutline",
            title: { _ in
                String(localized: "command.terminalToggleSessionOutline.title", defaultValue: "Toggle Session Outline")
            },
            subtitle: subtitle,
            keywords: ["terminal", "session", "outline", "transcript", "conversation", "toc", "jump", "agent"],
            when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
        )
    }

    func registerSessionOutlineCommandPaletteHandler(
        _ registry: inout CommandPaletteHandlerRegistry,
        tabManager: TabManager
    ) {
        registry.register(commandId: "palette.terminalToggleSessionOutline") {
            if !tabManager.toggleFocusedSessionOutline() {
                NSSound.beep()
            }
        }
    }
}
