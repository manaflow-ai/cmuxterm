import Foundation
import XCTest

final class SourceControlWorkspaceRootUITests: BrowserFixtureSocketTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        super.tearDown()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testSourceControlKeepsWorkspaceRootAcrossModesAndRefresh() throws {
        let firstRepository = try createRepositoryDirectory(fileName: "first-change.txt")
        let secondRepository = try createRepositoryDirectory(fileName: "second-change.txt")
        let app = try launchApp(additionalLaunchArguments: [
            "-sourceControl.beta.enabled", "YES",
            "-fileExplorer.isVisible", "YES",
            "-rightSidebar.tabs.hidden", "()",
        ])

        try createRepositoryWorkspace(directory: firstRepository, title: "Source Control first repository")
        app.activate()

        let filesButton = app.buttons["RightSidebarModeButton.files"]
        XCTAssertTrue(filesButton.waitForExistence(timeout: 10))
        filesButton.click()
        let sourceControlButton = app.buttons["RightSidebarModeButton.sourceControl"]
        XCTAssertTrue(sourceControlButton.waitForExistence(timeout: 10))
        sourceControlButton.click()

        let firstChange = app.buttons["first-change.txt, U"]
        XCTAssertTrue(firstChange.waitForExistence(timeout: 20), "Source Control must retain the selected workspace's Git root")
        XCTAssertFalse(app.staticTexts["No workspace selected"].exists)

        filesButton.click()
        sourceControlButton.click()
        XCTAssertTrue(firstChange.waitForExistence(timeout: 20))

        try "added during Source Control display\n".write(
            to: firstRepository.appendingPathComponent("refreshed-change.txt"),
            atomically: true,
            encoding: .utf8
        )
        let refreshButton = app.buttons["Refresh Source Control"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 10))
        refreshButton.click()
        let refreshedChange = app.buttons["refreshed-change.txt, U"]
        XCTAssertTrue(refreshedChange.waitForExistence(timeout: 20))

        try createRepositoryWorkspace(directory: secondRepository, title: "Source Control second repository")
        XCTAssertTrue(app.buttons["second-change.txt, U"].waitForExistence(timeout: 20))
        XCTAssertFalse(firstChange.exists, "The previous workspace's changes must not leak into the selected repository")
        XCTAssertFalse(refreshedChange.exists)
    }

    private func createRepositoryWorkspace(directory: URL, title: String) throws {
        _ = try socketResult(method: "workspace.create", params: [
            "title": title,
            "working_directory": directory.path,
            "initial_command": "/usr/bin/git init --quiet --initial-branch=main && exec /bin/zsh -f",
            "focus": true,
        ])
        let repositoryHead = directory.appendingPathComponent(".git/HEAD")
        let initialized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: repositoryHead.path)
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [initialized], timeout: 20), .completed, "The workspace shell must initialize a real Git repository")
    }

    private func createRepositoryDirectory(fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-source-control-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        try "untracked source-control fixture\n".write(
            to: directory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }
}
