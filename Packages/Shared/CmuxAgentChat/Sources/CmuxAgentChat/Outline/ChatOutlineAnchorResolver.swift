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
    ///   - history: Physical terminal rows in top-to-bottom order.
    /// - Returns: The matching row, or `nil` when terminal history no longer
    ///   contains the prompt.
    public func row(
        for entry: ChatOutlineEntry,
        among entries: [ChatOutlineEntry],
        in history: String
    ) -> Int? {
        let target = normalized(entry.title)
        guard !target.isEmpty else { return nil }
        let occurrence = entries
            .prefix { $0.id != entry.id }
            .filter { normalized($0.title) == target }
            .count

        let rows = history
            .components(separatedBy: .newlines)
            .map(normalized)
        var matchingOccurrence = 0
        for row in rows.indices {
            guard matches(target: target, startingAt: row, in: rows) else { continue }
            if matchingOccurrence == occurrence { return row }
            matchingOccurrence += 1
        }
        return nil
    }

    private func matches(target: String, startingAt row: Int, in rows: [String]) -> Bool {
        let firstRow = rows[row]
        if isPromptMatch(firstRow, target: target) {
            return true
        }

        var candidate = firstRow
        for nextRow in rows.dropFirst(row + 1) {
            guard !candidate.isEmpty else {
                candidate = nextRow
                continue
            }
            candidate += " " + nextRow
            if candidate.count >= target.count {
                return isWrappedPromptMatch(candidate, target: target)
            }
        }
        return false
    }

    private func isPromptMatch(_ candidate: String, target: String) -> Bool {
        candidate == target
    }

    private func isWrappedPromptMatch(_ candidate: String, target: String) -> Bool {
        let promptPrefixes = ["❯ ", "> ", "$ ", "% ", "# ", ">>> "]
        return promptPrefixes.contains { prefix in
            candidate.hasPrefix(prefix) && candidate.hasSuffix(" " + target)
        }
    }

    private func normalized(_ text: String) -> String {
        enum EscapeState {
            case none
            case afterEscape
            case csi
            case osc
            case oscEscape
        }

        var result = ""
        var escapeState = EscapeState.none
        var needsSpace = false

        for scalar in text.unicodeScalars {
            switch escapeState {
            case .afterEscape:
                if scalar == "[" {
                    escapeState = .csi
                } else if scalar == "]" {
                    escapeState = .osc
                } else {
                    escapeState = .none
                }
                continue
            case .csi:
                if (0x40...0x7E).contains(scalar.value) {
                    escapeState = .none
                } else if scalar.value == 0x1B {
                    escapeState = .afterEscape
                }
                continue
            case .osc:
                if scalar.value == 0x07 {
                    escapeState = .none
                } else if scalar.value == 0x1B {
                    escapeState = .oscEscape
                }
                continue
            case .oscEscape:
                escapeState = scalar == "\\" ? .none : .osc
                continue
            case .none:
                if scalar.value == 0x1B {
                    escapeState = .afterEscape
                    continue
                }
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
