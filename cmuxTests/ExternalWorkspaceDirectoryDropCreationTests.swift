import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Identity and create-at-index coverage for Finder-directory → new workspace.
///
/// Workspace identity is always the workspace UUID. Working directories and
/// titles are context/presentation only and must never dedupe creation.
@Suite struct ExternalWorkspaceDirectoryDropCreationTests {
    @MainActor
    @Test func sameWorkingDirectoryCreatesDistinctWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-drop-same-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TabManager()
        let first = try #require(manager.addWorkspaceIfActive(
            workingDirectory: root.path,
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        ))
        let second = try #require(manager.addWorkspaceIfActive(
            workingDirectory: root.path,
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: manager.tabs.count,
            autoWelcomeIfNeeded: false
        ))

        #expect(first.id != second.id)
        #expect(first.currentDirectory == root.path)
        #expect(second.currentDirectory == root.path)
        #expect(manager.selectedTabId == second.id)
    }

    @MainActor
    @Test func childAndParentDirectoriesCreateDistinctWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-drop-nest-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("mobile", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TabManager()
        let parentWorkspace = try #require(manager.addWorkspaceIfActive(
            workingDirectory: root.path,
            inheritWorkingDirectory: false,
            select: false,
            autoWelcomeIfNeeded: false
        ))
        let childWorkspace = try #require(manager.addWorkspaceIfActive(
            workingDirectory: child.path,
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: manager.tabs.count,
            autoWelcomeIfNeeded: false
        ))
        let parentAgain = try #require(manager.addWorkspaceIfActive(
            workingDirectory: root.path,
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: manager.tabs.count,
            autoWelcomeIfNeeded: false
        ))

        #expect(Set([parentWorkspace.id, childWorkspace.id, parentAgain.id]).count == 3)
        #expect(childWorkspace.currentDirectory == child.path)
        #expect(parentAgain.currentDirectory == root.path)
    }

    @MainActor
    @Test func sameBasenameDifferentPathsCreateDistinctWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-drop-basename-\(UUID().uuidString)", isDirectory: true)
        let clientA = root.appendingPathComponent("client-a/frontend", isDirectory: true)
        let clientB = root.appendingPathComponent("client-b/frontend", isDirectory: true)
        try FileManager.default.createDirectory(at: clientA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clientB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TabManager()
        let workspaceA = try #require(manager.addWorkspaceIfActive(
            workingDirectory: clientA.path,
            inheritWorkingDirectory: false,
            select: false,
            autoWelcomeIfNeeded: false
        ))
        let workspaceB = try #require(manager.addWorkspaceIfActive(
            workingDirectory: clientB.path,
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: manager.tabs.count,
            autoWelcomeIfNeeded: false
        ))

        #expect(workspaceA.id != workspaceB.id)
        #expect(workspaceA.currentDirectory == clientA.path)
        #expect(workspaceB.currentDirectory == clientB.path)
        #expect(URL(fileURLWithPath: clientA.path).lastPathComponent == "frontend")
        #expect(URL(fileURLWithPath: clientB.path).lastPathComponent == "frontend")
    }

    @MainActor
    @Test func duplicateVisibleTitlesDoNotBlockCreation() throws {
        let manager = TabManager()
        let first = try #require(manager.addWorkspaceIfActive(
            title: "Jimmy",
            inheritWorkingDirectory: false,
            select: false,
            autoWelcomeIfNeeded: false
        ))
        let second = try #require(manager.addWorkspaceIfActive(
            title: "Jimmy",
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: manager.tabs.count,
            autoWelcomeIfNeeded: false
        ))

        #expect(first.id != second.id)
        #expect(first.title == "Jimmy")
        #expect(second.title == "Jimmy")
    }

    @MainActor
    @Test func insertionIndexOverridePlacesWorkspaceBetweenNeighbors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-drop-order-\(UUID().uuidString)", isDirectory: true)
        let jimmy = root.appendingPathComponent("Jimmy", isDirectory: true)
        try FileManager.default.createDirectory(at: jimmy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TabManager()
        // TabManager boots with one workspace; build A B C explicitly.
        let a = try #require(manager.tabs.first)
        let b = try #require(manager.addWorkspaceIfActive(
            select: false,
            placementOverride: .end,
            autoWelcomeIfNeeded: false
        ))
        let c = try #require(manager.addWorkspaceIfActive(
            select: false,
            placementOverride: .end,
            autoWelcomeIfNeeded: false
        ))
        #expect(manager.tabs.map(\.id) == [a.id, b.id, c.id])

        let jimmyWorkspace = try #require(manager.addWorkspaceIfActive(
            workingDirectory: jimmy.path,
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: 1,
            autoWelcomeIfNeeded: false
        ))

        #expect(manager.tabs.map(\.id) == [a.id, jimmyWorkspace.id, b.id, c.id])
        #expect(jimmyWorkspace.currentDirectory == jimmy.path)
        #expect(manager.selectedTabId == jimmyWorkspace.id)
        #expect(!jimmyWorkspace.isPinned)
    }

    @MainActor
    @Test func insertionIndexOverrideClampsAfterPinnedPrefix() throws {
        let manager = TabManager()
        let pinned = try #require(manager.tabs.first)
        manager.setPinned(pinned, pinned: true)
        let unpinned = try #require(manager.addWorkspaceIfActive(
            select: false,
            placementOverride: .end,
            autoWelcomeIfNeeded: false
        ))

        let inserted = try #require(manager.addWorkspaceIfActive(
            workingDirectory: "/tmp",
            inheritWorkingDirectory: false,
            select: true,
            insertionIndexOverride: 0,
            autoWelcomeIfNeeded: false
        ))

        #expect(manager.tabs.map(\.id) == [pinned.id, inserted.id, unpinned.id])
        #expect(!inserted.isPinned)
    }
}
