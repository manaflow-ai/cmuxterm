import Foundation

/// Blueprint (per-terminal Excalidraw canvas) beta gate and settings reads for
/// non-SwiftUI callers. The keys mirror the `blueprint.beta.enabled` toggle in
/// `BetaFeaturesCatalogSection`; SwiftUI code should bind through the settings
/// catalog instead of reading these directly.
enum TerminalBlueprintFeature {
    static let enabledKey = "blueprint.beta.enabled"
    /// When on (default), an agent-authored scene opens a closed drawer so the
    /// user sees the update. When off, the drawer only shows an "updated" badge
    /// the next time it is opened.
    static let autoOpenOnAgentUpdateKey = "blueprint.autoOpenOnAgentUpdate"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    nonisolated static func autoOpensOnAgentUpdate(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoOpenOnAgentUpdateKey) != nil else { return true }
        return defaults.bool(forKey: autoOpenOnAgentUpdateKey)
    }

    // MARK: - Live setting file for the agent wrappers

    /// The Claude Code and Codex wrappers attach the `cmux-blueprint` MCP
    /// server only while this file says `1`. It mirrors the beta toggle so a
    /// live change applies to the next agent launch without a respawn.
    nonisolated static func liveSettingFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/cmux/blueprint", isDirectory: true)
            .appendingPathComponent("enabled", isDirectory: false)
    }

    /// Writes the toggle's current value to the live setting file.
    @discardableResult
    nonisolated static func syncLiveSettingFile(
        defaults: UserDefaults = .standard,
        fileURL: URL = liveSettingFileURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        let value = isEnabled(defaults: defaults) ? "1\n" : "0\n"
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let existing = try? String(contentsOf: fileURL, encoding: .utf8), existing == value {
                return true
            }
            try Data(value.utf8).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
