import Foundation

/// The blueprint drawer state persisted with a terminal panel's session
/// snapshot. The scene itself lives in `TerminalBlueprintStore`, keyed by the
/// panel's stable surface id, so the session file stays small.
struct SessionTerminalBlueprintSnapshot: Codable, Equatable, Sendable {
    var isOpen: Bool
    var layout: TerminalBlueprintLayout
    var revision: Int

    init(isOpen: Bool, layout: TerminalBlueprintLayout, revision: Int) {
        self.isOpen = isOpen
        self.layout = layout
        self.revision = revision
    }
}
