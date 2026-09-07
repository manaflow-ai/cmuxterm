import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    func sessionOutlineChanges() -> AsyncStream<String> {
        sessionOutlineChangeBus.stream()
    }

    func sessionOutline(for surfaceID: UUID) async -> [ChatOutlineEntry]? {
        guard let record = registry.currentOrMostRecentSession(
            surfaceID: surfaceID.uuidString
        ) else {
            return nil
        }
        guard let page = await history(
            sessionID: record.sessionID,
            beforeSeq: nil,
            limit: 4_000
        ) else {
            return nil
        }
        return ChatOutlineBuilder().entries(from: page.messages)
    }
}
