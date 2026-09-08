import Darwin
import Foundation
import Testing
import Bonsplit
import CmuxCore
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationTests {
    @MainActor
    @Test
    func testClearingAgentPIDByPanelClearsOnlyThatPanelLifecycleWhenSameStatusKeyRemains() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.recordAgentPID(key: "codex.first", pid: 111, panelId: firstPanelId, refreshPorts: false)
        workspace.recordAgentPID(key: "codex.second", pid: 222, panelId: secondPanelId, refreshPorts: false)
        workspace.setAgentLifecycle(key: "codex", panelId: firstPanelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanelId, lifecycle: .running)

        expectTrue(workspace.clearAgentPID(key: "codex.first", panelId: firstPanelId, clearStatus: true, refreshPorts: false))

        expectEqual(workspace.agentHibernationLifecycleState(panelId: firstPanelId, fallback: nil), .unknown)
        expectEqual(workspace.agentHibernationLifecycleState(panelId: secondPanelId, fallback: nil), .running)
    }

    @Test
    func testSessionIndexLoadsAgentLifecycleFromHookStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-hibernation-lifecycle"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    @Test
    func testSessionIndexUsesLiveHookPIDAsProcessID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-live-hook-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let pid = 12_345
        let identity = AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: 42, startMicroseconds: 7)
        let sessionId = "codex-live-hook-pid"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": pid,
                    "pidStartSeconds": identity.startSeconds,
                    "pidStartMicroseconds": identity.startMicroseconds,
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/bin/sleep",
                        "arguments": ["/bin/sleep", "30"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { requestedPID in
                requestedPID == pid
                    ? CmuxTopProcessArguments(
                        arguments: ["/bin/sleep", "30"],
                        environment: [
                            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                            "CMUX_SURFACE_ID": panelId.uuidString,
                            "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.codex.rawValue,
                        ]
                    )
                    : nil
            },
            processIdentityProvider: { requestedPID in
                requestedPID == pid ? identity : nil
            }
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func testSessionIndexAcceptsNodeBackedClaudeProcessAsLiveHookPID() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-claude-node-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let pid = 23_456
        let identity = AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: 43, startMicroseconds: 8)
        let sessionId = "claude-node-live-hook-pid"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-tmp-repo", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"summary","summary":"Claude session"}"#.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )

        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "transcriptPath": transcriptURL.path,
                    "pid": pid,
                    "pidStartSeconds": identity.startSeconds,
                    "pidStartMicroseconds": identity.startMicroseconds,
                    "agentLifecycle": "idle",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/opt/homebrew/bin/claude",
                        "arguments": ["/opt/homebrew/bin/claude"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { requestedPID in
                requestedPID == pid
                    ? CmuxTopProcessArguments(
                        arguments: [
                            "/opt/homebrew/Cellar/node/24.0.0/bin/node",
                            "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                        ],
                        environment: [
                            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
                            "CMUX_SURFACE_ID": panelId.uuidString,
                            "CMUX_AGENT_LAUNCH_KIND": RestorableAgentKind.claude.rawValue,
                        ]
                    )
                    : nil
            },
            processIdentityProvider: { requestedPID in
                requestedPID == pid ? identity : nil
            }
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [pid])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func testLiveProcessScopeMatchingAcceptsLegacyEnvironmentKeys() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let process = CmuxTopProcessArguments(
            arguments: ["/usr/bin/codex"],
            environment: [
                "CMUX_TAB_ID": workspaceId.uuidString,
                "CMUX_PANEL_ID": panelId.uuidString,
            ]
        )

        expectTrue(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: panelId))
        expectFalse(process.matchesCMUXScope(workspaceId: UUID(), surfaceId: panelId))
        expectFalse(process.matchesCMUXScope(workspaceId: workspaceId, surfaceId: UUID()))
    }

    @Test
    func testSessionIndexDoesNotDropHookStoreForUnknownAgentLifecycle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-index-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "codex-hibernation-future-lifecycle"
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "paused",
                    "updatedAt": Date().timeIntervalSince1970,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .unknown)
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId, sessionId)
    }

    @Test
    func testProcessDetectedSnapshotPreservesMatchingHookLifecycleWithoutRefreshingActivity() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-detected-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "opencode-detected-lifecycle"
        let hookUpdatedAt: TimeInterval = 123
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([123, 456]), agentProcessIDs: Set([123]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [123, 456])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

    @Test
    func testProcessDetectedSnapshotPreservesMatchingHookLifecycleWhenHookPIDIsStale() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-stale-pid-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "opencode-restored-stale-pid"
        let hookUpdatedAt: TimeInterval = 456
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": 999_999,
                    "agentLifecycle": "idle",
                    "updatedAt": hookUpdatedAt,
                    "launchCommand": [
                        "launcher": "opencode",
                        "executablePath": "/usr/local/bin/opencode",
                        "arguments": ["/usr/local/bin/opencode"],
                        "workingDirectory": "/tmp/repo",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: sessionId,
            workingDirectory: "/tmp/repo",
            launchCommand: launch(
                "opencode",
                "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", sessionId],
                cwd: "/tmp/repo"
            )
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([321]), agentProcessIDs: Set([321]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectEqual(index.lifecycle(workspaceId: workspaceId, panelId: panelId), .idle)
        expectEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), hookUpdatedAt)
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [321])
        expectEqual(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.launchCommand?.executablePath, "/opt/homebrew/bin/opencode")
    }

}
