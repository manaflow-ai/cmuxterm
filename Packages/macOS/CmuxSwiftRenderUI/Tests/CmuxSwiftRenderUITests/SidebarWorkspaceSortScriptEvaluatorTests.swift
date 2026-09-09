import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite("SidebarWorkspaceSortScriptEvaluator")
struct SidebarWorkspaceSortScriptEvaluatorTests {
    private func input(_ title: String, index: Int) -> SidebarWorkspaceSortScriptInput {
        SidebarWorkspaceSortScriptInput(
            id: UUID(),
            title: title,
            manualIndex: index,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            isSelected: index == 0,
            isPinned: false,
            groupId: nil,
            directory: "/tmp/\(title)",
            gitBranch: nil,
            gitIsDirty: false
        )
    }

    @Test func acceptsWorkspaceObjectsReturnedByAComparatorSort() throws {
        let workspaces = [input("Zulu", index: 0), input("Alpha", index: 1)]
        let result = SidebarWorkspaceSortScriptEvaluator.evaluate(
            source: """
            function orderWorkspaces(workspaces) {
              return [...workspaces].sort((a, b) => a.title.localeCompare(b.title));
            }
            """,
            workspaces: workspaces
        )

        #expect(try result.get() == [workspaces[1].id, workspaces[0].id])
    }

    @Test func acceptsAListOfWorkspaceIds() throws {
        let workspaces = [input("First", index: 0), input("Second", index: 1)]
        let result = SidebarWorkspaceSortScriptEvaluator.evaluate(
            source: """
            function orderWorkspaces(workspaces) {
              return [workspaces[1].id];
            }
            """,
            workspaces: workspaces
        )

        #expect(try result.get() == [workspaces[1].id])
    }

    @Test func rejectsMissingFunctionUnknownIdsAndDuplicates() {
        let workspace = input("Only", index: 0)

        #expect(SidebarWorkspaceSortScriptEvaluator.evaluate(
            source: "const value = 1;",
            workspaces: [workspace]
        ).failure?.message.contains("orderWorkspaces") == true)

        #expect(SidebarWorkspaceSortScriptEvaluator.evaluate(
            source: "function orderWorkspaces() { return ['00000000-0000-0000-0000-000000000000']; }",
            workspaces: [workspace]
        ).failure?.message.contains("unknown") == true)

        #expect(SidebarWorkspaceSortScriptEvaluator.evaluate(
            source: "function orderWorkspaces(workspaces) { return [workspaces[0], workspaces[0]]; }",
            workspaces: [workspace]
        ).failure?.message.contains("more than once") == true)
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
