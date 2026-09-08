/// Prompt attribution for one native terminal lifetime.
///
/// Absolute rows are never reused after Ghostty invalidates their row space.
/// The last submitted text is independent of history so the live view can
/// still show it after a clear, resize, or unavailable position capture.
public struct TerminalPromptHistory: Sendable {
    /// Entries in strictly increasing retained-row order.
    public private(set) var entries: [TerminalPromptHistoryEntry] = []
    /// The latest submitted message, including submissions without an anchor.
    public private(set) var latest: TerminalPromptHistoryEntry?

    /// Starts an empty history for a native terminal lifetime.
    public init() {}

    /// Records a submission without duplicating entries at the same row.
    ///
    /// A cursor moving backwards invalidates subsequent boundaries: an agent
    /// may have redrawn that part of the active screen. Replacing that suffix
    /// also bounds history to distinct rows of retained terminal content.
    @discardableResult
    public mutating func record(
        preview: String,
        anchor: TerminalPromptAnchor?
    ) -> TerminalPromptHistoryEntry? {
        let normalized = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let validAnchor = anchor.flatMap { $0.row >= 0 ? $0 : nil }
        let entry = TerminalPromptHistoryEntry(preview: normalized, anchor: validAnchor)
        latest = entry
        guard let validAnchor else {
            entries.removeAll()
            return entry
        }
        reconcile(rowSpaceRevision: validAnchor.rowSpaceRevision)
        let insertionIndex = lowerBound(for: validAnchor.row)
        entries.removeSubrange(insertionIndex...)
        entries.append(entry)
        return entry
    }

    /// Discards positions invalidated by trimming, reflow, or a screen switch.
    public mutating func reconcile(rowSpaceRevision: UInt64) {
        if let revision = entries.first?.anchor?.rowSpaceRevision,
           revision != rowSpaceRevision {
            entries.removeAll()
        }
    }

    /// Selects the owning turn in logarithmic time without moving the viewport.
    ///
    /// Content before the first known prompt has no attributable turn. Returning
    /// the first future prompt there would label unrelated output incorrectly.
    public func selectedEntry(
        viewportTopRow: Int,
        isAtBottom: Bool,
        rowSpaceRevision: UInt64
    ) -> TerminalPromptHistoryEntry? {
        if isAtBottom { return latest }
        guard entries.first?.anchor?.rowSpaceRevision == rowSpaceRevision else { return nil }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if let row = entries[middle].anchor?.row, row <= viewportTopRow {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? entries[lower - 1] : nil
    }

    private func lowerBound(for row: Int) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if let middleRow = entries[middle].anchor?.row, middleRow < row {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
