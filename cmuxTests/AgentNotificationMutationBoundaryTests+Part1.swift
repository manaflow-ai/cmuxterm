import CmuxControlSocket
import CmuxCore
import CmuxSidebar
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Oversized Cursor metadata ignores conversation aliases")
    func oversizedCursorMetadataUsesOnlySessionIdentifiers() {
        var scanner = CMUXCLI.CursorNativeApprovalRootFieldScanner()
        scanner.consume(
            Data(
                #"{"conversation_id":"conversation","tool_use_id":"tool","session_id":"session"}"#.utf8
            )
        )

        #expect(scanner.metadata?.sessionId == "session")
        #expect(scanner.metadata?.toolCallId == "tool")
    }

    @Test("Generic hook recovery does not trust a merely live inferred PID")
    func genericHookRecoveryRequiresProcessBindingCorroboration() {
        let cli = CMUXCLI(args: [])
        let currentPID = Int(getpid())

        #expect(
            cli.preferredAgentHookEventPID(
                agentName: "cursor",
                mappedPID: 999_991,
                inferredPID: currentPID
            ) == 999_991,
            "A live wrapper or shell PID is not ownership proof for a generic hook."
        )
        #expect(
            cli.preferredAgentHookEventPID(
                agentName: "claude",
                mappedPID: nil,
                inferredPID: currentPID
            ) == nil,
            "Without a mapped owner, an uncorroborated generic PID must fail closed."
        )
    }

    @Test("Custom remote agent PID registration does not require a local identity")
    func customRemoteAgentPIDRegistrationAllowsOpaqueNamespace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "remote-custom-agent",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_010,
            relayID: "custom-remote-pid-registration",
            relayToken: String(repeating: "p", count: 64),
            localSocketPath: "/tmp/cmux-custom-remote-pid-registration.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh remote-custom-agent"
        )
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let result = ControlSidebarPanelOwner.workspace(workspace).recordAgentPID(
            key: "custom.remote-session",
            pid: 424_242,
            panelId: panelID,
            acceptedProcessIdentity: nil,
            observeProcessExit: false
        )
        guard result.accepted else {
            Issue.record("Opaque remote custom PID registration was rejected")
            return
        }
        #expect(workspace.agentPIDs["custom.remote-session"] == 424_242)
        #expect(
            workspace.agentPIDProcessIdentitiesByKey["custom.remote-session"] == nil
        )
    }

    @Test("Scheduled remote custom PID registration keeps the PID opaque")
    func scheduledRemoteCustomPIDRegistrationDoesNotUseLocalGeneration() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "remote-scheduled-custom-agent",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_011,
            relayID: "scheduled-custom-remote-pid",
            relayToken: String(repeating: "q", count: 64),
            localSocketPath: "/tmp/cmux-scheduled-custom-remote-pid.sock",
            ownerWorkspaceID: workspace.id,
            terminalStartupCommand: "ssh remote-scheduled-custom-agent"
        )
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let key = "custom.remote-scheduled"
        let localPID = Int32(getpid())
        TerminalController.shared.controlSidebarScheduleAgentPIDRecord(
            target: .workspace(workspace.id),
            key: key,
            pid: localPID,
            processGeneration: nil,
            panelID: panelID
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(workspace.agentPIDs[key] == localPID)
        #expect(
            workspace.agentPIDProcessIdentitiesByKey[key] == nil,
            "A PID from a remote namespace must not be reconstructed against the local process table."
        )
    }

    @Test("Rejected PID registration preserves an active Feed attention token")
    func rejectedPIDRegistrationDoesNotEraseFeedAttention() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let token = try #require(
            workspace.beginAgentFeedAttention(
                key: "cursor",
                panelId: panelID,
                processGeneration: generation
            )
        )
        defer {
            _ = workspace.endAgentFeedAttention(
                key: "cursor",
                panelId: panelID,
                token: token
            )
        }

        let mismatchedGeneration = AgentPIDProcessIdentity(
            pid: generation.pid,
            startSeconds: generation.startSeconds + 1,
            startMicroseconds: generation.startMicroseconds
        )
        let result = ControlSidebarPanelOwner.workspace(workspace).recordAgentPID(
            key: "cursor.rejected-registration",
            pid: generation.pid,
            panelId: panelID,
            acceptedProcessIdentity: mismatchedGeneration,
            observeProcessExit: false
        )
        guard !result.accepted else {
            Issue.record("The mismatched PID registration was unexpectedly accepted")
            return
        }
        #expect(
            workspace.sidebarAgentRuntimeObservation.hasAgentFeedAttention(
                key: "cursor",
                panelId: panelID
            ),
            "A rejected registration is not proof that the active prompt process exited."
        )
    }

    @Test("Workspace-scoped PID ownership authorizes lifecycle updates")
    func workspaceScopedPIDAuthorizesLifecycleWithoutPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        let panelID = try #require(workspace.focusedPanelId)
        let generation = try #require(
            AgentPIDProcessIdentity(pid: getpid())
        )
        let owner = ControlSidebarPanelOwner.workspace(workspace)
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.setDrainsSuspendedForTesting(false)
            bus.discardPendingNotifications()
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        guard owner.recordAgentPID(
            key: "codex.workspace-scoped",
            pid: generation.pid,
            panelId: nil,
            acceptedProcessIdentity: generation,
            observeProcessExit: false
        ).accepted else {
            Issue.record("The workspace-scoped PID registration was rejected")
            return
        }
        let processGeneration = ControlSidebarAgentProcessGeneration(
            pid: generation.pid,
            startSeconds: generation.startSeconds,
            startMicroseconds: generation.startMicroseconds
        )
        TerminalController.shared.controlSidebarScheduleAgentLifecycle(
            target: .workspace(workspace.id),
            key: "codex",
            lifecycleRawValue: AgentHibernationLifecycleState.running.rawValue,
            processGeneration: processGeneration,
            panelID: nil
        )
        bus.setDrainsSuspendedForTesting(false)
        bus.drainForTesting()

        #expect(
            workspace.agentLifecycleStatesByPanelId[panelID]?["codex"]
                == .running,
            "An exact workspace-scoped PID must authorize the tab lifecycle path."
        )
    }

    @Test("Panel transfer preserves lifecycle-owned status without a PID key")
    func panelTransferPreservesLifecycleOwnedStatusWithoutPID() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let status = SidebarStatusEntry(
            key: "amp",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        workspace.statusEntries["amp"] = status
        let remoteGeneration = AgentPIDProcessIdentity(
            pid: 42_424,
            startSeconds: 1_700_000_000,
            startMicroseconds: 123
        )

        #expect(
            workspace.setAgentLifecycle(
                key: "amp",
                panelId: panelID,
                lifecycle: .running,
                processGeneration: remoteGeneration
            )
        )
        let runtime = try #require(
            workspace.agentRuntimeState(forPanelId: panelID)
        )
        #expect(runtime.agentPIDs.isEmpty)
        #expect(runtime.agentLifecycleStates["amp"] == .running)
        #expect(
            runtime.statusEntries["amp"] == status,
            "A lifecycle-owned remote status must remain visible when its panel moves without a local PID key."
        )
    }

    // Generous for loaded CI runners: subprocess spawn, signal propagation,
    // and marker writes can take multiple seconds there. A long timeout only
    // slows the failure path.
    func waitForMarker(at url: URL, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @Test("PID routing bypasses a stale negative telemetry cache after exec")
    func pidResolutionBypassesStaleNegativeTelemetryCacheAfterExec() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-live-pid-exec-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initialScript = root.appendingPathComponent("initial.sh")
        let scopedScript = root.appendingPathComponent("scoped.sh")
        let readyMarker = root.appendingPathComponent("ready")
        let execMarker = root.appendingPathComponent("execed")
        try """
        touch '\(readyMarker.path)'
        trap 'exec /bin/sh "\(scopedScript.path)"' USR1
        while :; do sleep 1; done
        """.write(to: initialScript, atomically: true, encoding: .utf8)
        try """
        export CMUX_SURFACE_ID='\(fixture.panelId.uuidString)'
        exec /bin/sh -c 'touch "\(execMarker.path)"; exec sleep 30'
        """.write(to: scopedScript, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [initialScript.path]
        var environment = ProcessInfo.processInfo.environment
        ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID", "CMUX_PANEL_ID"].forEach {
            environment.removeValue(forKey: $0)
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: root)
        }
        #expect(await waitForMarker(at: readyMarker))

        let identity = try #require(agentLiveProcessIdentity(pid: process.processIdentifier))
        let cachedMiss = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: Int(process.processIdentifier),
            cacheKey: identity.scopeCacheKey,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        #expect(cachedMiss == nil)
        #expect(Darwin.kill(process.processIdentifier, SIGUSR1) == 0)
        #expect(await waitForMarker(at: execMarker))

        #expect(
            fixture.appDelegate.liveAgentDeliveryTarget(forAgentPID: process.processIdentifier)
                == AgentDeliveryTargetCandidate(
                    workspaceId: fixture.source.id,
                    surfaceId: fixture.panelId
                )
        )
    }

    @Test("Local PID routing excludes remote TTY device namespaces")
    func localTTYBindingsExcludeRemoteDeviceNamespaces() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.registerReportedSurfaceTTYName("/dev/null", panelId: panelId)
        #expect(workspace.localAgentDeliveryTTYDevices.map(\.surfaceId) == [panelId])

        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        #expect(workspace.localAgentDeliveryTTYDevices.isEmpty)
    }

    @Test("Restored TTY metadata requires a fresh runtime registration")
    func restoredTTYMetadataRequiresFreshRuntimeRegistration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let snapshot = SessionPanelSnapshot(
            id: panelId,
            type: .terminal,
            title: "Restored terminal",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: "/dev/null",
            terminal: SessionTerminalPanelSnapshot(),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )

        workspace.applySessionPanelMetadata(snapshot, toPanelId: panelId)

        #expect(workspace.surfaceTTYNames[panelId] == "/dev/null")
        #expect(
            workspace.localAgentDeliveryTTYDevices.isEmpty,
            "Persisted TTY metadata is not evidence from the current terminal runtime"
        )

        workspace.pruneSurfaceMetadata(validSurfaceIds: [panelId])
        #expect(
            workspace.localAgentDeliveryTTYDevices.isEmpty,
            "Metadata pruning must not promote a persisted TTY into live evidence"
        )

        workspace.registerReportedSurfaceTTYName("/dev/null", panelId: panelId)
        #expect(workspace.localAgentDeliveryTTYDevices.map(\.surfaceId) == [panelId])
    }

}
