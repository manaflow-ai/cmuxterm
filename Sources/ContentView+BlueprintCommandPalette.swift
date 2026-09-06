import AppKit
import CmuxCommandPalette

extension ContentView {
    static func commandPaletteBlueprintContributions() -> [CommandPaletteCommandContribution] {
        guard TerminalBlueprintFeature.isEnabled() else { return [] }
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }
        return [
            CommandPaletteCommandContribution(
                commandId: "palette.terminalToggleBlueprint",
                title: constant(String(localized: "command.toggleBlueprint.title", defaultValue: "Toggle Blueprint")),
                subtitle: constant(String(localized: "command.toggleBlueprint.subtitle", defaultValue: "Show or hide the diagram canvas of the focused terminal")),
                keywords: ["blueprint", "canvas", "diagram", "sketch", "draw", "excalidraw", "whiteboard", "terminal"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.terminalCollapseBlueprint",
                title: constant(String(localized: "command.collapseBlueprint.title", defaultValue: "Collapse or Expand Blueprint")),
                subtitle: constant(String(localized: "command.collapseBlueprint.subtitle", defaultValue: "Minimize the blueprint to its header, or bring it back")),
                keywords: ["blueprint", "canvas", "collapse", "expand", "minimize", "diagram"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.terminalEnlargeBlueprint",
                title: constant(String(localized: "command.enlargeBlueprint.title", defaultValue: "Enlarge or Restore Blueprint")),
                subtitle: constant(String(localized: "command.enlargeBlueprint.subtitle", defaultValue: "Give the blueprint most of the pane, or restore the split")),
                keywords: ["blueprint", "canvas", "enlarge", "maximize", "restore", "diagram"]
            ),
        ]
    }

    func registerBlueprintCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.terminalToggleBlueprint") {
            if !tabManager.performBlueprintAction(.toggle) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalCollapseBlueprint") {
            let isExpanded = tabManager.selectedTerminalPanel?.blueprint.isExpanded ?? false
            if !tabManager.performBlueprintAction(isExpanded ? .collapse : .expand) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalEnlargeBlueprint") {
            let isEnlarged = tabManager.selectedTerminalPanel?.blueprint.layout.isEnlarged ?? false
            if !tabManager.performBlueprintAction(isEnlarged ? .restore : .enlarge) {
                NSSound.beep()
            }
        }
    }
}
