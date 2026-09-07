import Foundation

/// Reduces parsed transcript messages to navigable user-turn summaries.
public struct ChatOutlineBuilder: Sendable {
    /// Creates an outline builder.
    public init() {}

    /// Builds user-turn entries from parsed transcript messages.
    ///
    /// - Parameter messages: Messages in transcript order.
    /// - Returns: One entry per non-empty user prose message, with actionable
    ///   agent questions and permission requests attributed to the preceding
    ///   user turn.
    public func entries(from messages: [ChatMessage]) -> [ChatOutlineEntry] {
        var entries: [ChatOutlineEntry] = []
        var lastEntryIndex: Int?

        for message in messages.sorted(by: { $0.seq < $1.seq }) {
            if message.role == .user {
                lastEntryIndex = nil
                guard let title = title(for: message), !title.isEmpty else {
                    continue
                }
                entries.append(ChatOutlineEntry(
                    id: message.id,
                    seq: message.seq,
                    timestamp: message.timestamp,
                    title: title,
                    hasAlert: false
                ))
                lastEntryIndex = entries.index(before: entries.endIndex)
                continue
            }

            guard isActionable(message), let lastEntryIndex else { continue }
            let entry = entries[lastEntryIndex]
            entries[lastEntryIndex] = ChatOutlineEntry(
                id: entry.id,
                seq: entry.seq,
                timestamp: entry.timestamp,
                title: entry.title,
                hasAlert: true
            )
        }

        return entries
    }

    private func title(for message: ChatMessage) -> String? {
        switch message.kind {
        case .prose(let prose):
            return firstLine(of: prose.text)
        case .attachment(let attachment):
            guard let displayName = attachment.displayName,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return firstLine(of: displayName)
        default:
            return nil
        }
    }

    private func firstLine(of text: String) -> String {
        let line = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first
            .map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private func isActionable(_ message: ChatMessage) -> Bool {
        switch message.kind {
        case .permissionRequest, .question:
            return true
        default:
            return false
        }
    }
}
