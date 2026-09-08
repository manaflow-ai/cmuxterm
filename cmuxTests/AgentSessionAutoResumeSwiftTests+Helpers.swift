import Darwin
import Foundation
import CMUXAgentLaunch
import CmuxCore
import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentSessionAutoResumeSwiftTests {
    @MainActor
    func restoreResumedAgentWorkspaceWithClobberedTrackedCwd(
        projectDir: String
    ) throws -> (workspace: Workspace, panelId: UUID, homeDirectory: String) {
        let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedClaudeAgent(
            savedDirectory: projectDir
        )
        try #require(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
        )

        let homeDir = try clobberResumedAgentTrackedCwd(
            restored,
            panelId: restoredPanelId,
            projectDir: projectDir
        )
        return (restored, restoredPanelId, homeDir)
    }

    @MainActor
    func restoreResumedRestorableAgentOnlyWorkspaceWithClobberedTrackedCwd(
        projectDir: String
    ) throws -> (workspace: Workspace, panelId: UUID, homeDirectory: String) {
        let (restored, restoredPanelId) = try restoreWorkspaceWithAutoResumedRestorableClaudeAgentOnly(
            savedDirectory: projectDir
        )
        try #require(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .autoResumeCommandRunning
        )

        let homeDir = try clobberResumedAgentTrackedCwd(
            restored,
            panelId: restoredPanelId,
            projectDir: projectDir
        )
        return (restored, restoredPanelId, homeDir)
    }

    @MainActor
    func clobberResumedAgentTrackedCwd(
        _ restored: Workspace,
        panelId restoredPanelId: UUID,
        projectDir: String
    ) throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        try #require(homeDir != projectDir)

        // First spurious report: swallowed by the one-shot #6617 guard.
        restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeDir)
        try #require(restored.panelDirectories[restoredPanelId] == projectDir)

        // Second stray report: the guard is spent, so home lands in every
        // tracked record while the resumed agent still runs in `projectDir`.
        restored.updatePanelDirectory(panelId: restoredPanelId, directory: homeDir)
        try #require(restored.panelDirectories[restoredPanelId] == homeDir)
        try #require(restored.currentDirectory == homeDir)

        return homeDir
    }

    func makeTemporaryProjectDirectory(prefix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @MainActor
    func restoreWorkspaceWithAutoResumedClaudeAgent(
        savedDirectory: String
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let sessionId = "claude-cmdt-resume-\(UUID().uuidString)"
        let source = Workspace()
        source.currentDirectory = savedDirectory
        let sourcePanelId = try #require(source.focusedPanelId)

        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: savedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", sessionId],
                workingDirectory: savedDirectory,
                environment: [:],
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Claude",
                kind: "claude",
                command: "{ cd -- '\(savedDirectory)' 2>/dev/null || [ ! -d '\(savedDirectory)' ]; } && 'claude' '--resume' '\(sessionId)'",
                cwd: savedDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])

        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        #expect(snapshot.currentDirectory == savedDirectory)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        // Restore replays the persisted directory onto the workspace and panel.
        #expect(restored.currentDirectory == savedDirectory)
        #expect(restored.panelDirectories[restoredPanelId] == savedDirectory)

        return (restored, restoredPanelId)
    }

    /// Builds a workspace whose focused terminal hosts an auto-resumable
    /// restorable Claude session rooted at `savedDirectory` without an
    /// agent-hook binding, snapshots it, and restores it into a fresh workspace.
    @MainActor
    func restoreWorkspaceWithAutoResumedRestorableClaudeAgentOnly(
        savedDirectory: String
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let sessionId = "claude-restorable-only-resume-\(UUID().uuidString)"
        let source = Workspace()
        source.currentDirectory = savedDirectory
        let sourcePanelId = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelId, directory: savedDirectory)

        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: savedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", sessionId],
                workingDirectory: savedDirectory,
                environment: [:],
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(agent, panelId: sourcePanelId)

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.terminal?.agent?.workingDirectory == savedDirectory)
        #expect(snapshot.panels.first?.terminal?.resumeBinding == nil)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        #expect(restored.currentDirectory == savedDirectory)
        #expect(restored.panelDirectories[restoredPanelId] == savedDirectory)
        #expect(restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding == nil)

        return (restored, restoredPanelId)
    }

    /// Builds a workspace that restores solely from a cmux-owned agent-hook
    /// binding: no restorable-agent snapshot is present, but the approved
    /// binding still auto-runs a startup command rooted at `savedDirectory`.
    @MainActor
    func restoreWorkspaceWithAutoResumedAgentHookBindingOnly(
        savedDirectory: String
    ) throws -> (workspace: Workspace, panelId: UUID) {
        let sessionId = "claude-binding-only-resume-\(UUID().uuidString)"
        let source = Workspace()
        source.currentDirectory = savedDirectory
        let sourcePanelId = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelId, directory: savedDirectory)
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Claude",
                kind: "claude",
                command: "{ cd -- '\(savedDirectory)' 2>/dev/null || [ ! -d '\(savedDirectory)' ]; } && 'claude' '--resume' '\(sessionId)'",
                cwd: savedDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            ),
        ])

        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        #expect(snapshot.panels.first?.terminal?.agent == nil)
        #expect(snapshot.panels.first?.terminal?.resumeBinding?.cwd == savedDirectory)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)

        #expect(restored.currentDirectory == savedDirectory)
        #expect(restored.panelDirectories[restoredPanelId] == savedDirectory)

        return (restored, restoredPanelId)
    }

    func expectedClaudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    func writeClaudeTranscript(sessionId: String, transcriptURL: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    func writeClaudeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"))
    }

    func claudeHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        configDir: String,
        transcriptPath: String?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "pid": NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": launchCwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
    }

    func withRestoredDefaults<T>(
        key: String,
        defaults: UserDefaults = .standard,
        body: () throws -> T
    ) rethrows -> T {
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }

    @MainActor
    func assertAgentAutoResumeUsesStartupInput(
        _ panel: TerminalPanel,
        scriptContains needles: [String],
        scriptDoesNotContain excludedNeedles: [String] = []
    ) throws {
        #expect(panel.surface.debugInitialCommand() == nil)
        let input = try #require(panel.surface.debugInitialInputForTesting())
        let launcherPrefix = "/bin/zsh '"
        let launcherRange = try #require(input.range(of: launcherPrefix, options: .backwards))
        let launcherSuffix = input[launcherRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(launcherSuffix.hasSuffix("'"), Comment(rawValue: input))
        let scriptPath = String(launcherSuffix.dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        for needle in needles {
            #expect(script.contains(needle), Comment(rawValue: script))
        }
        for needle in excludedNeedles {
            #expect(!script.contains(needle), Comment(rawValue: script))
        }
        #expect(script.contains("rm -f -- \"$0\""), Comment(rawValue: script))
        #expect(!script.contains("exec -l"), Comment(rawValue: script))
    }
}
