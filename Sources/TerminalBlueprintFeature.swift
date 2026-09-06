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
}
