import CmuxAgentChat
import Foundation

struct SessionOutlineCache {
    struct Value {
        let revision: UInt64
        let entries: [ChatOutlineEntry]
    }

    private var revisions: [String: UInt64] = [:]
    private var values: [String: Value] = [:]

    func revision(for sessionID: String) -> UInt64 {
        revisions[sessionID, default: 0]
    }

    func value(for sessionID: String, revision: UInt64) -> [ChatOutlineEntry]? {
        guard let value = values[sessionID], value.revision == revision else { return nil }
        return value.entries
    }

    mutating func store(_ entries: [ChatOutlineEntry], for sessionID: String, revision: UInt64) {
        values[sessionID] = Value(revision: revision, entries: entries)
    }

    mutating func invalidate(sessionID: String) {
        revisions[sessionID, default: 0] &+= 1
        values[sessionID] = nil
    }

    mutating func remove(sessionID: String) {
        revisions[sessionID] = nil
        values[sessionID] = nil
    }
}

extension AgentChatTranscriptService {
    func sessionOutlineChanges(for surfaceID: UUID) -> AsyncStream<Void> {
        sessionOutlineState.changeBus.stream(surfaceID: surfaceID.uuidString)
    }

    func sessionOutline(for surfaceID: UUID) async -> [ChatOutlineEntry]? {
        guard let record = registry.currentOrMostRecentSession(
            surfaceID: surfaceID.uuidString
        ) else {
            return nil
        }
        let sessionID = record.sessionID
        let revision = sessionOutlineState.cache.revision(for: sessionID)
        if let cached = sessionOutlineState.cache.value(for: sessionID, revision: revision) {
            return cached
        }
        guard let page = await history(
            sessionID: sessionID,
            beforeSeq: nil,
            limit: 4_000
        ) else {
            return nil
        }
        let messages = page.messages
        let entries = await Task.detached(priority: .userInitiated) {
            ChatOutlineBuilder().entries(from: messages)
        }.value
        guard sessionOutlineState.cache.revision(for: sessionID) == revision else {
            return entries
        }
        sessionOutlineState.cache.store(entries, for: sessionID, revision: revision)
        return entries
    }
}
