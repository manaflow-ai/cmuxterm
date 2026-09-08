import CmuxAgentChat
import Foundation
import Testing

@Suite("Chat outline builder")
struct ChatOutlineBuilderTests {
    @Test("summarizes user turns and badges actionable responses")
    func summarizesUserTurnsAndBadgesActionableResponses() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let messages = [
            ChatMessage(
                id: "prompt-1",
                seq: 10,
                role: .user,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: "Investigate the login flow\nwith a focused test"))
            ),
            ChatMessage(
                id: "permission-1",
                seq: 11,
                role: .agent,
                timestamp: timestamp,
                kind: .permissionRequest(ChatPermissionRequest(
                    title: "Permission required",
                    subject: "Run the focused test"
                ))
            ),
            ChatMessage(
                id: "prompt-2",
                seq: 20,
                role: .user,
                timestamp: timestamp.addingTimeInterval(60),
                kind: .prose(ChatProse(text: "Document the result"))
            ),
        ]

        let entries = ChatOutlineBuilder().entries(from: messages)

        #expect(entries.map(\.title) == ["Investigate the login flow", "Document the result"])
        #expect(entries.map(\.seq) == [10, 20])
        #expect(entries.map(\.hasAlert) == [true, false])
        #expect(entries.map(\.id) == ["prompt-1", "prompt-2"])
        #expect(entries.map(\.timestamp) == [timestamp, timestamp.addingTimeInterval(60)])
    }

    @Test("does not badge resolved requests")
    func doesNotBadgeResolvedRequests() {
        let messages = [
            ChatMessage(
                id: "prompt-1",
                seq: 10,
                role: .user,
                timestamp: Date(timeIntervalSince1970: 1_000),
                kind: .prose(ChatProse(text: "Review the completed requests"))
            ),
            ChatMessage(
                id: "permission-1",
                seq: 11,
                role: .agent,
                timestamp: Date(timeIntervalSince1970: 1_001),
                kind: .permissionRequest(ChatPermissionRequest(
                    title: "Permission required",
                    subject: "Run the command",
                    resolution: .approved
                ))
            ),
            ChatMessage(
                id: "question-1",
                seq: 12,
                role: .agent,
                timestamp: Date(timeIntervalSince1970: 1_002),
                kind: .question(ChatQuestion(
                    prompt: "Which option?",
                    options: [ChatQuestion.Option(label: "Safe")],
                    selectedOptionLabel: "Safe"
                ))
            ),
        ]

        let entries = ChatOutlineBuilder().entries(from: messages)

        #expect(entries.map(\.hasAlert) == [false])
    }
}
