import Foundation

/// Locates an outline prompt in captured terminal history.
public struct ChatOutlineAnchorResolver: Sendable {
    /// Creates an anchor resolver.
    public init() {}

    /// Returns the zero-based terminal row containing an outline prompt.
    ///
    /// - Parameters:
    ///   - entry: The prompt to locate.
    ///   - entries: The complete visible outline, used to disambiguate equal
    ///     prompt titles.
    ///   - history: Terminal history rows in top-to-bottom order.
    /// - Returns: The matching row, or `nil` when terminal history no longer
    ///   contains the prompt.
    public func row(
        for entry: ChatOutlineEntry,
        among entries: [ChatOutlineEntry],
        in history: String
    ) -> Int? {
        let occurrence = entries
            .prefix { $0.id != entry.id }
            .filter { $0.title == entry.title }
            .count
        let target = normalized(entry.title)
        guard !target.isEmpty else { return nil }

        var matchingOccurrence = 0
        for (row, rawLine) in history.components(separatedBy: .newlines).enumerated() {
            guard normalized(rawLine).contains(target) else { continue }
            if matchingOccurrence == occurrence { return row }
            matchingOccurrence += 1
        }
        return nil
    }

    private func normalized(_ text: String) -> String {
        var result = ""
        var isInEscapeSequence = false
        var needsSpace = false

        for scalar in text.unicodeScalars {
            if isInEscapeSequence {
                if (0x40...0x7E).contains(scalar.value) {
                    isInEscapeSequence = false
                }
                continue
            }
            if scalar.value == 0x1B {
                isInEscapeSequence = true
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                needsSpace = !result.isEmpty
                continue
            }
            if needsSpace {
                result.append(" ")
                needsSpace = false
            }
            result.unicodeScalars.append(scalar)
        }
        return result.lowercased()
    }
}
