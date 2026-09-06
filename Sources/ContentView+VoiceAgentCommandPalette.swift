import AppKit
import CmuxCommandPalette

extension ContentView {
    static func commandPaletteVoiceAgentContributions() -> [CommandPaletteCommandContribution] {
        guard VoiceAgentFeature.isEnabled() else { return [] }
        return [CommandPaletteCommandContribution(
            commandId: "palette.toggleVoiceAgent",
            title: { _ in String(localized: "command.toggleVoiceAgent.title", defaultValue: "Toggle Voice Agent") },
            subtitle: { _ in String(localized: "command.toggleVoiceAgent.subtitle", defaultValue: "Talk to cmux to control workspaces, panes, terminals, and the browser") },
            keywords: ["voice", "talk", "speak", "microphone", "mic", "agent", "ultravox", "pipecat"]
        )]
    }

    func registerVoiceAgentCommandPaletteHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.toggleVoiceAgent") {
            guard let appDelegate = AppDelegate.shared,
                  appDelegate.performVoiceAgentToggle(preferredWindow: appDelegate.mainWindow(for: windowId)) else {
                NSSound.beep()
                return
            }
        }
    }
}
