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
    @Test
    func testProcessDetectedSnapshotPreservesHookLifecycleWhenRestoredPanelIDsChange() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-remapped-panel-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.opencode.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let oldWorkspaceId = UUID()
        let oldPanelId = UUID()
        let currentWorkspaceId = UUID()
        let currentPanelId = UUID()
        let sessionId = "opencode-restored-remapped-panel"
        let hookUpdatedAt: TimeInterval = 789
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": oldWorkspaceId.uuidString,
                    "surfaceId": oldPanelId.uuidString,
                    "cwd": "/tmp/repo",
                    "pid": 999_998,
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

        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: currentWorkspaceId, panelId: currentPanelId)
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
                    processIDs: Set([654]), agentProcessIDs: Set([654]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectNil(index.snapshot(workspaceId: oldWorkspaceId, panelId: oldPanelId))
        expectEqual(index.lifecycle(workspaceId: currentWorkspaceId, panelId: currentPanelId), .idle)
        expectEqual(index.updatedAt(workspaceId: currentWorkspaceId, panelId: currentPanelId), hookUpdatedAt)
        expectEqual(index.processIDs(workspaceId: currentWorkspaceId, panelId: currentPanelId), [654])
    }

    @Test
    func testProcessDetectedOnlySnapshotDoesNotUseScanTimeAsActivity() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-empty-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-detected-only",
            workingDirectory: "/tmp/repo",
            launchCommand: launch("opencode", "/usr/local/bin/opencode", cwd: "/tmp/repo")
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: Set([789]), agentProcessIDs: Set([789]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        expectEqual(index.updatedAt(workspaceId: workspaceId, panelId: panelId), 0)
        expectNil(index.lifecycle(workspaceId: workspaceId, panelId: panelId))
        expectEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [789])
        expectTrue(index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId))
    }

    @Test
    func testSupportedAgentSnapshotsHaveResumeCommandsForHibernation() {
        let cwd = "/tmp/cmux-agent-hibernation"
        let sessionId = "session-123"
        let launchCommands: [(RestorableAgentKind, AgentLaunchCommandSnapshot)] = [
            (.claude, launch("claude", "/usr/local/bin/claude", cwd: cwd)),
            (.codex, launch("codex", "/usr/local/bin/codex", cwd: cwd)),
            (.opencode, launch("opencode", "/usr/local/bin/opencode", cwd: cwd)),
            (.pi, launch("pi", "/usr/local/bin/pi", cwd: cwd)),
            (.amp, launch("amp", "/usr/local/bin/amp", cwd: cwd)),
            (.cursor, launch("cursor", "/usr/local/bin/cursor-agent", cwd: cwd)),
            (.gemini, launch("gemini", "/usr/local/bin/gemini", cwd: cwd)),
            (.rovodev, launch("rovodev", "/usr/local/bin/acli", arguments: ["/usr/local/bin/acli", "rovodev", "run"], cwd: cwd)),
            (.hermesAgent, launch("hermes-agent", "/usr/local/bin/hermes", cwd: cwd)),
            (.copilot, launch("copilot", "/usr/local/bin/copilot", cwd: cwd)),
            (.codebuddy, launch("codebuddy", "/usr/local/bin/codebuddy", cwd: cwd)),
            (.factory, launch("factory", "/usr/local/bin/droid", cwd: cwd)),
            (.qoder, launch("qoder", "/usr/local/bin/qodercli", cwd: cwd)),
        ]

        for (kind, launchCommand) in launchCommands {
            let snapshot = SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionId,
                workingDirectory: cwd,
                launchCommand: launchCommand
            )
            expectNotNil(snapshot.resumeCommand, "\(kind.rawValue) should be resumable before hibernation can use it")
            expectFalse(snapshot.agentDisplayName.isEmpty)
        }
    }

    @Test
    func testCustomRegisteredAgentSnapshotCanHibernateWhenResumeCommandExists() {
        let registration = CmuxVaultAgentRegistration(
            id: "local-agent",
            name: "Local Agent",
            detect: CmuxVaultAgentDetectRule(processName: "local-agent"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "{{executable}} resume {{sessionId}}",
            cwd: .preserve
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("local-agent"),
            sessionId: "custom-session",
            workingDirectory: "/tmp/custom-agent",
            launchCommand: launch("local-agent", "/usr/local/bin/local-agent", cwd: "/tmp/custom-agent"),
            registration: registration
        )

        expectEqual(snapshot.agentDisplayName, "Local Agent")
        expectEqual(snapshot.resumeCommand, "cd -- '/tmp/custom-agent' 2>/dev/null || [ ! -d '/tmp/custom-agent' ] && '/usr/local/bin/local-agent' 'resume' 'custom-session'")
    }

    @MainActor
    @Test
    func testInvalidatedIndexedAgentSnapshotIsNotEligibleForHibernation() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hibernation-invalidated-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-invalidated-index",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                key: (
                    snapshot: snapshot,
                    updatedAt: 100,
                    processIDs: Set([42]), agentProcessIDs: Set([42]),
                    sessionIDSource: .explicit
                ),
            ]
        )

        workspace.invalidatedRestoredAgentFingerprintsByPanelId[panelId] =
            TabManager.restorableAgentSnapshotFingerprint(snapshot)

        expectNil(workspace.restorableAgentForHibernation(panelId: panelId, index: index))
    }

    @MainActor
    @Test
    func testHibernationRetiresPanelPortsAndScannerLifecycle() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-port-retirement",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        let scannerKey = PortScanner.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let staleTTYName = "/dev/ttys9152"
        PortScanner.shared.registerTTY(
            workspaceId: workspace.id,
            panelId: panelId,
            ttyName: staleTTYName
        )
        defer {
            PortScanner.shared.unregisterPanel(workspaceId: workspace.id, panelId: panelId)
        }
        workspace.surfaceListeningPorts[panelId] = [4321]
        workspace.recomputeListeningPorts()

        try #require(workspace.enterAgentHibernation(
            panelId: panelId,
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))

        expectNil(workspace.surfaceListeningPorts[panelId])
        expectTrue(workspace.listeningPorts.isEmpty)
        expectNil(PortScanner.shared.publicationState.registeredPanelTTYName(for: scannerKey))
        let persistedPanel = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panelId }
        )
        expectTrue(persistedPanel.listeningPorts.isEmpty)
    }

    @MainActor
    @Test
    func testRestoringHibernatedPanelDiscardsPersistedPorts() throws {
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        let sourcePanel = try #require(source.panels[sourcePanelId] as? TerminalPanel)
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-restored-port-retirement",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )
        try #require(sourcePanel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))
        var legacyPanelSnapshot = try #require(
            source.sessionSnapshot(includeScrollback: false).panels.first { $0.id == sourcePanelId }
        )
        try #require(legacyPanelSnapshot.terminal?.hibernation != nil)
        legacyPanelSnapshot.listeningPorts = [4321]

        let restored = Workspace()
        let restoredPanelId = try #require(restored.focusedPanelId)
        restored.applySessionPanelMetadata(legacyPanelSnapshot, toPanelId: restoredPanelId)
        restored.recomputeListeningPorts()

        expectNil(restored.surfaceListeningPorts[restoredPanelId])
        expectTrue(restored.listeningPorts.isEmpty)
    }

    @MainActor
    @Test
    func testFocusingHibernatedTerminalAutomaticallyPreparesResume() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-auto-resume-on-visit",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        workspace.focusPanel(panelId)

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testVisibleHibernatedTerminalAutomaticallyPreparesResumeWithoutFocus() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-visible-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        expectTrue(workspace.resumeVisibleAgentHibernationPanels(panelIds: [panelId]))

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testHiddenMountedWorkspaceDoesNotAutoResumeHibernatedTerminal() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-hidden-mounted-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )
        expectTrue(panel.isAgentHibernated)

        workspace.setAgentHibernationAutoResumePresentationVisible(false)
        expectEqual(workspace.agentHibernationVisiblePanelIdsForCurrentLayout(), [])

        _ = workspace.debugReconcileTerminalPortalVisibilityForTesting()
        expectTrue(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .manualResumeAvailable)

        workspace.setAgentHibernationAutoResumePresentationVisible(true)

        expectFalse(panel.isAgentHibernated)
        expectEqual(workspace.restoredAgentResumeStatesByPanelId[panelId], .awaitingAutoResumeCommand)
    }

    @MainActor
    @Test
    func testAutosaveFingerprintTracksHibernationTransitions() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-autosave-hibernation",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        let liveFingerprint = manager.sessionAutosaveFingerprint()
        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        let hibernatedFingerprint = manager.sessionAutosaveFingerprint()

        expectNotEqual(liveFingerprint, hibernatedFingerprint)
        expectTrue(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        expectNotEqual(hibernatedFingerprint, manager.sessionAutosaveFingerprint())
    }

    @MainActor
    @Test
    func testResumeClearsStaleLifecycleState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-clear-lifecycle-on-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: launch("codex", "/usr/local/bin/codex", cwd: "/tmp/cmux-agent-hibernation")
        )

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)
        workspace.enterAgentHibernation(
            panelId: panelId,
            agent: snapshot,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        expectTrue(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
        expectEqual(workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil), .unknown)
    }

}
