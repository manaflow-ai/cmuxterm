import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct ExternalWorkspaceDirectoryDropValidatorTests {
    @Test func acceptsExactlyOneLocalDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/Jimmy", isDirectory: true)
        let validator = ExternalWorkspaceDirectoryDropValidator { url in
            #expect(url.path == directory.path)
            return .directory
        }

        let result = validator.validate([directory])
        guard case .success(let accepted) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(accepted.path == "/tmp/Jimmy")
        #expect(accepted.url.standardizedFileURL == directory.standardizedFileURL)
    }

    @Test func rejectsRegularFile() {
        let file = URL(fileURLWithPath: "/tmp/photo.png", isDirectory: false)
        let validator = ExternalWorkspaceDirectoryDropValidator { _ in .file }
        #expect(validator.validate([file]) == .failure(.notDirectory))
    }

    @Test func rejectsMultipleURLs() {
        let first = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
        let validator = ExternalWorkspaceDirectoryDropValidator { _ in .directory }
        #expect(validator.validate([first, second]) == .failure(.multipleItems))
    }

    @Test func rejectsEmptyPayload() {
        let validator = ExternalWorkspaceDirectoryDropValidator { _ in .directory }
        #expect(validator.validate([]) == .failure(.emptyPayload))
    }

    @Test func rejectsMissingPath() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let validator = ExternalWorkspaceDirectoryDropValidator { _ in .missing }
        #expect(validator.validate([missing]) == .failure(.missingPath))
    }

    @Test func rejectsNonFileURL() {
        let remote = URL(string: "https://example.com/project")!
        let validator = ExternalWorkspaceDirectoryDropValidator { _ in .directory }
        #expect(validator.validate([remote]) == .failure(.notLocalFileURL))
    }

    @Test func stripsTrailingSlashWithoutResolvingSymlinkIdentity() {
        let directory = URL(fileURLWithPath: "/tmp/Jimmy/", isDirectory: true)
        let validator = ExternalWorkspaceDirectoryDropValidator { _ in .directory }
        let result = validator.validate([directory])
        guard case .success(let accepted) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(accepted.path == "/tmp/Jimmy")
    }

    @Test func liveFileManagerProbeAcceptsCreatedDirectoryAndRejectsFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-external-dir-drop-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("Jimmy", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let validator = ExternalWorkspaceDirectoryDropValidator()
        guard case .success(let accepted) = validator.validate([directory]) else {
            Issue.record("Expected live directory to be accepted")
            return
        }
        #expect(accepted.path == directory.path)
        #expect(validator.validate([file]) == .failure(.notDirectory))
    }
}

@Suite struct ExternalWorkspaceInsertionPlannerTests {
    private func targets(
        _ ids: [UUID],
        pinned: Set<UUID> = [],
        height: CGFloat = 32,
        gap: CGFloat = 8
    ) -> [ExternalWorkspaceInsertionPlanner.RootTarget] {
        ids.enumerated().map { index, id in
            ExternalWorkspaceInsertionPlanner.RootTarget(
                workspaceId: id,
                isPinned: pinned.contains(id),
                frame: CGRect(
                    x: 0,
                    y: CGFloat(index) * (height + gap),
                    width: 180,
                    height: height
                )
            )
        }
    }

    @Test func emptyRootTargetsReturnNilFromPlan() {
        let plan = ExternalWorkspaceInsertionPlanner().plan(
            point: CGPoint(x: 12, y: 2),
            rootTargets: []
        )
        #expect(plan == nil)
        let empty = ExternalWorkspaceInsertionPlanner().planForEmptySidebar()
        #expect(empty.insertionIndex == 0)
    }

    @Test func insertsBeforeFirstOrdinaryWorkspace() {
        let first = UUID()
        let second = UUID()
        let rootTargets = targets([first, second])
        let plan = ExternalWorkspaceInsertionPlanner().plan(
            point: CGPoint(x: 12, y: 2),
            rootTargets: rootTargets
        )
        #expect(plan?.insertionIndex == 0)
        #expect(plan?.indicator == SidebarDropIndicator(tabId: first, edge: .top))
    }

    @Test func insertsBetweenOrdinaryWorkspaces() {
        let first = UUID()
        let second = UUID()
        let rootTargets = targets([first, second])
        // Top edge of second row (y=40..72): edge band → insert before second.
        let plan = ExternalWorkspaceInsertionPlanner().plan(
            point: CGPoint(x: 12, y: 42),
            rootTargets: rootTargets
        )
        #expect(plan?.insertionIndex == 1)
        #expect(plan?.indicator == SidebarDropIndicator(tabId: second, edge: .top))
    }

    @Test func appendsAfterLastWorkspace() {
        let first = UUID()
        let second = UUID()
        let rootTargets = targets([first, second])
        let plan = ExternalWorkspaceInsertionPlanner().plan(
            point: CGPoint(x: 12, y: 65),
            rootTargets: rootTargets
        )
        #expect(plan?.insertionIndex == 2)
        #expect(plan?.indicator == SidebarDropIndicator(tabId: nil, edge: .bottom))
    }

    @Test func rejectsRowCenterSoExistingWorkspaceIsNotImplied() {
        let first = UUID()
        let second = UUID()
        let rootTargets = targets([first, second])
        let plan = ExternalWorkspaceInsertionPlanner().plan(
            point: CGPoint(x: 12, y: 56),
            rootTargets: rootTargets
        )
        #expect(plan == nil)
    }

    @Test func clampsUnpinnedInsertionAfterPinnedPrefix() {
        let pinned = UUID()
        let first = UUID()
        let second = UUID()
        let rootTargets = targets([pinned, first, second], pinned: [pinned])
        // Point on the top edge of the pinned row would propose index 0; clamp
        // keeps a new unpinned workspace after the pinned segment.
        let plan = ExternalWorkspaceInsertionPlanner().plan(
            point: CGPoint(x: 12, y: 2),
            rootTargets: rootTargets
        )
        #expect(plan?.insertionIndex == 1)
        #expect(plan?.indicator == SidebarDropIndicator(tabId: first, edge: .top))
    }

    @Test func mapsTopLevelSlotToRawTabIndex() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let planner = ExternalWorkspaceInsertionPlanner()
        #expect(planner.rawTabInsertionIndex(forTopLevelSlot: 1, topLevelIds: [a, b, c], tabIds: [a, b, c]) == 1)
        #expect(planner.rawTabInsertionIndex(forTopLevelSlot: 3, topLevelIds: [a, b, c], tabIds: [a, b, c]) == 3)
        #expect(planner.rawTabInsertionIndex(forTopLevelSlot: 0, topLevelIds: [a, b], tabIds: [a, b, c]) == 0)
    }
}
