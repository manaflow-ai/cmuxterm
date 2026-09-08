import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Workspace agent checklist sync")
struct WorkspaceAgentChecklistSyncTests {
    @Test("agent reports replace only their own rows")
    func preservesUserAndOtherAgentRows() throws {
        let user = WorkspaceChecklistItem(text: "User note")
        let otherRef = WorkspaceAgentTaskRef(workstreamId: "other", taskId: "1")
        let other = WorkspaceChecklistItem(text: "Other task", origin: .agent, agentTaskRef: otherRef)
        let existing = [user, other]
        let current = WorkspaceAgentChecklistTask(
            id: UUID(),
            ref: WorkspaceAgentTaskRef(workstreamId: "current", taskId: "2"),
            text: "Current task",
            state: .inProgress,
            lastActivityAt: Date(timeIntervalSince1970: 42),
            agentName: "claude"
        )
        let replacements = try #require(WorkspaceAgentChecklistSync().replacement(
            existing: existing,
            agentTasks: [current],
            workstreamId: "current"
        ))
        #expect(replacements.map(\.text) == ["User note", "Other task", "Current task"])
        #expect(replacements.last?.agentTaskRef == current.ref)
        #expect(replacements.last?.lastActivityAt == Date(timeIntervalSince1970: 42))
    }

    @Test("an empty report retires only the reporting agent")
    func emptyReportRetiresRows() throws {
        let currentRef = WorkspaceAgentTaskRef(workstreamId: "current", taskId: "1")
        let otherRef = WorkspaceAgentTaskRef(workstreamId: "other", taskId: "1")
        let existing = [
            WorkspaceChecklistItem(text: "current", origin: .agent, agentTaskRef: currentRef),
            WorkspaceChecklistItem(text: "other", origin: .agent, agentTaskRef: otherRef),
        ]
        let replacements = try #require(WorkspaceAgentChecklistSync().replacement(
            existing: existing,
            agentTasks: [],
            workstreamId: "current"
        ))
        #expect(replacements.map(\.text) == ["other"])
    }

    @Test("an empty report retires legacy aliases of the canonical workstream")
    func emptyReportRetiresMatchingAliases() throws {
        let legacyRef = WorkspaceAgentTaskRef(workstreamId: "legacy", taskId: "1")
        let canonicalRef = WorkspaceAgentTaskRef(workstreamId: "canonical", taskId: "2")
        let existing = [
            WorkspaceChecklistItem(text: "legacy", origin: .agent, agentTaskRef: legacyRef),
            WorkspaceChecklistItem(text: "canonical", origin: .agent, agentTaskRef: canonicalRef),
            WorkspaceChecklistItem(text: "user")
        ]
        let replacements = try #require(WorkspaceAgentChecklistSync().replacement(
            existing: existing,
            agentTasks: [],
            workstreamId: "canonical",
            matchingWorkstreamIds: ["legacy", "canonical"]
        ))
        #expect(replacements.map(\.text) == ["user"])
    }

    @Test("authoritative task ids preserve a matching provisional row identity")
    func authoritativeTaskIdPreservesProvisionalIdentity() throws {
        let provisionalRef = WorkspaceAgentTaskRef(workstreamId: "current", taskId: "pending-1")
        let existing = [
            WorkspaceChecklistItem(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                text: "Restore this task",
                origin: .agent,
                agentTaskRef: provisionalRef,
                dispatchTarget: WorkspaceTaskDispatchTarget(
                    workingDirectory: "/tmp/project",
                    agentCommand: "claude --continue",
                    agentName: "claude"
                )
            )
        ]
        let authoritative = WorkspaceAgentChecklistTask(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            ref: WorkspaceAgentTaskRef(workstreamId: "current", taskId: "42"),
            text: "Restore this task",
            state: .inProgress,
            agentName: "claude"
        )

        let replacements = try #require(WorkspaceAgentChecklistSync().replacement(
            existing: existing,
            agentTasks: [authoritative],
            workstreamId: "current"
        ))

        #expect(replacements.first?.id == existing.first?.id)
        #expect(replacements.first?.dispatchTarget == existing.first?.dispatchTarget)
        #expect(replacements.first?.boundWorkspaceID == existing.first?.boundWorkspaceID)
        #expect(replacements.first?.boundAgent == existing.first?.boundAgent)
        #expect(replacements.first?.agentTaskRef == authoritative.ref)

        var checklist = existing
        guard case .success = checklist.replaceChecklist(with: replacements) else {
            Issue.record("expected the identity-preserving replacement to apply")
            return
        }
        #expect(WorkspaceAgentChecklistSync().replacement(
            existing: checklist,
            agentTasks: [authoritative],
            workstreamId: "current"
        ) == nil)
    }

    @Test("dispatch metadata survives Codable round trip")
    func dispatchMetadataRoundTrips() throws {
        let item = WorkspaceChecklistItem(
            text: "Run tests",
            dispatchTarget: WorkspaceTaskDispatchTarget(
                workingDirectory: "/tmp/project",
                agentCommand: "claude --continue",
                agentName: "claude"
            ),
            boundWorkspaceID: UUID(),
            boundAgent: "claude",
            lastActivityAt: Date(timeIntervalSince1970: 7)
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WorkspaceChecklistItem.self, from: data)
        #expect(decoded.dispatchTarget == item.dispatchTarget)
        #expect(decoded.boundWorkspaceID == item.boundWorkspaceID)
        #expect(decoded.boundAgent == "claude")
        #expect(decoded.lastActivityAt == item.lastActivityAt)
    }
}
