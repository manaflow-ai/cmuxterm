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
    func testLifecycleStateParsingAcceptsShellFriendlyAliases() throws {
        expectEqual(AgentHibernationLifecycleState(cliValue: "IDLE"), .idle)
        expectEqual(AgentHibernationLifecycleState(cliValue: "needsInput"), .needsInput)
        expectEqual(AgentHibernationLifecycleState(cliValue: "needs-input"), .needsInput)
        expectEqual(AgentHibernationLifecycleState(cliValue: "needs_input"), .needsInput)
        expectNil(AgentHibernationLifecycleState(cliValue: "paused"))

        let decoded = try JSONDecoder().decode(
            AgentHibernationLifecycleState.self,
            from: Data(#""paused""#.utf8)
        )
        expectEqual(decoded, .unknown)
    }

    @MainActor
    @Test
    func testSocketLifecycleRejectsUnsupportedStatusKey() {
        let response = TerminalController.shared.handleSocketLine("set_agent_lifecycle fake-agent idle")

        expectTrue(response.contains("Unsupported agent lifecycle key"))
    }

    @MainActor
    @Test
    func testBuiltInSocketEvidenceRequiresLivePanelProcess() throws {
        let previousManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let target =
            "--tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"

        expectTrue(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle codex running \(target)"
            ).contains("process generation is required")
        )
        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_status codex Running \(target)"
            ),
            "OK"
        )
        TerminalMutationBus.shared.drainForTesting()

        expectNil(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"]
        )
        expectNil(workspace.statusEntries["codex"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
        let processIdentity = try #require(
            AgentPIDProcessIdentity(pid: process.processIdentifier)
        )
        let processGenerationOptions =
            "--pid=\(processIdentity.pid) "
            + "--pid-start-seconds=\(processIdentity.startSeconds) "
            + "--pid-start-microseconds="
            + "\(processIdentity.startMicroseconds)"
        defer {
            workspace.clearAgentPID(
                key: "codex.socket-test",
                panelId: panelId,
                clearStatus: true,
                refreshPorts: false
            )
        }

        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_agent_pid codex.socket-test "
                    + "\(process.processIdentifier) \(target) "
                    + processGenerationOptions
            ),
            "OK"
        )
        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle codex idle \(target) "
                    + "--pid=\(processIdentity.pid) "
                    + "--pid-start-seconds="
                    + "\(processIdentity.startSeconds - 1) "
                    + "--pid-start-microseconds="
                    + "\(processIdentity.startMicroseconds)"
            ),
            "OK"
        )
        TerminalMutationBus.shared.drainForTesting()
        expectNil(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"]
        )

        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle codex running \(target) "
                    + processGenerationOptions
            ),
            "OK"
        )
        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_status codex Running \(target)"
            ),
            "OK"
        )
        TerminalMutationBus.shared.drainForTesting()

        expectEqual(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"],
            .running
        )
        expectEqual(workspace.statusEntries["codex"]?.value, "Running")
    }

    @MainActor
    @Test
    func testRemoteSocketEvidenceDoesNotResolvePIDAgainstLocalHost() throws {
        let previousManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "remote.example",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-remote-agent-test.sock",
            terminalStartupCommand: "ssh remote.example"
        )
        let target =
            "--tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        let remotePID = Int32.max
        let remoteGenerationOptions =
            "--pid=\(remotePID) --pid-start-seconds=200 "
            + "--pid-start-microseconds=300"

        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_agent_pid codex.remote-session \(remotePID) \(target) "
                    + remoteGenerationOptions
            ),
            "OK"
        )
        expectTrue(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle codex running \(target)"
            ).contains("process generation is required")
        )
        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle codex running \(target) "
                    + remoteGenerationOptions
            ),
            "OK"
        )
        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle codex idle \(target) "
                    + "--pid=\(remotePID) --pid-start-seconds=199 "
                    + "--pid-start-microseconds=300"
            ),
            "OK"
        )
        expectEqual(
            TerminalController.shared.handleSocketLine(
                "set_status codex Running --pid=\(remotePID) \(target)"
            ),
            "OK"
        )
        TerminalMutationBus.shared.drainForTesting()

        expectNil(workspace.agentPIDs["codex.remote-session"])
        expectEqual(
            workspace.agentLifecycleStatesByPanelId[panelId]?["codex"],
            .running
        )
        expectEqual(workspace.statusEntries["codex"]?.value, "Running")
    }

    @MainActor
    @Test
    func testSocketLifecycleAcceptsRegisteredCustomAgentKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-custom-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "vault": {
            "agents": [
              {
                "id": "local-agent",
                "name": "Local Agent",
                "detect": { "processName": "local-agent" },
                "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
                "resumeCommand": "local-agent --session {{sessionId}}",
                "cwd": "preserve"
              }
            ]
          }
        }
        """.write(to: configDirectory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.panelDirectories[panelId] = root.path

        let response = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle local-agent idle --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        expectEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        expectEqual(workspace.agentLifecycleStatesByPanelId[panelId]?["local-agent"], .idle)
    }

    @Test
    func testSettingsDefaultToOptInAndNotifyOnChanges() throws {
        let suiteName = "cmux-agent-hibernation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expectFalse(AgentHibernationSettings.isEnabled(defaults: defaults))
        expectEqual(AgentHibernationSettings.idleSeconds(defaults: defaults), 5)
        expectEqual(AgentHibernationSettings.maxLiveTerminals(defaults: defaults), 12)

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: AgentHibernationSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        AgentHibernationSettings.setValues(
            enabled: true,
            idleSeconds: 10,
            maxLiveTerminals: 4,
            defaults: defaults,
            notificationCenter: notificationCenter
        )

        let values = AgentHibernationSettings.values(defaults: defaults)
        expectTrue(values.enabled)
        expectEqual(values.idleSeconds, 10)
        expectEqual(values.maxLiveTerminals, 4)
        expectEqual(notificationCount, 1)

        defaults.set(42, forKey: AgentHibernationSettings.confirmationSecondsKey)
        expectEqual(AgentHibernationSettings.confirmationSeconds(defaults: defaults), 42)
        AgentHibernationSettings.reset(defaults: defaults, notificationCenter: notificationCenter)
        expectEqual(AgentHibernationSettings.confirmationSeconds(defaults: defaults), AgentHibernationSettings.defaultConfirmationSeconds)
        expectNil(defaults.object(forKey: AgentHibernationSettings.confirmationSecondsKey))
        expectEqual(notificationCount, 2)

        AgentHibernationSettings.setValues(
            enabled: AgentHibernationSettings.defaultEnabled,
            idleSeconds: AgentHibernationSettings.defaultIdleSeconds,
            maxLiveTerminals: AgentHibernationSettings.defaultMaxLiveTerminals,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        expectEqual(notificationCount, 2)
    }

    @Test
    func testPlannerOnlySelectsIdleUnprotectedExcessLiveAgents() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let idleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let idleNew = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let runningOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let needsInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unknownOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unconfirmedInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let visibleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(key: idleOld, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: idleNew, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 10),
                .init(key: runningOld, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .running, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: needsInputOld, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .needsInput, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: unknownOld, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .unknown, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: unconfirmedInputOld, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: true, lastActivityAt: now - 300),
                .init(key: visibleOld, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: true, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
            ],
            settings: settings,
            now: now
        )

        expectEqual(selected, Set([idleOld]))
    }

    @Test
    func testPlannerDoesNotSelectWhenUnderLiveLimit() {
        let key = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 2,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(key: key, hasRestorableAgent: true, isLive: true, processSafetyAllowsHibernation: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: 0),
            ],
            settings: settings,
            now: 1_000
        )

        expectTrue(selected.isEmpty)
    }

    @Test
    func testScrollbackFingerprintIncludesProcessIDs() {
        let first = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [7, 3]
        )
        let sameIDsDifferentOrder = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [3, 7]
        )
        let restarted = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [8]
        )

        expectEqual(first, sameIDsDifferentOrder)
        expectNotEqual(first, restarted)
    }

    @Test
    func testFirstTailSampleStartsObservedStabilityWindow() {
        expectEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: nil,
                previousStableSince: nil,
                currentFingerprint: "tail-a",
                lastActivityAt: 100,
                now: 500
            ),
            500
        )
        expectEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-a",
                lastActivityAt: 120,
                now: 500
            ),
            100
        )
        expectEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-b",
                lastActivityAt: 120,
                now: 500
            ),
            500
        )
    }

}
