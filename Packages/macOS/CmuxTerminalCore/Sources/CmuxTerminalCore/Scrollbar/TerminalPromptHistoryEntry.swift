/// A submitted prompt and its optional, verified terminal position.
public struct TerminalPromptHistoryEntry: Equatable, Sendable {
    /// User-authored text, collapsed to a single line.
    public let preview: String
    /// Nil when submission could not capture a trustworthy row.
    public let anchor: TerminalPromptAnchor?

    /// Creates an entry without interpreting its user-authored content.
    public init(preview: String, anchor: TerminalPromptAnchor?) {
        self.preview = preview
        self.anchor = anchor
    }
}
