import CmuxCore
import CmuxRemoteWorkspace
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Each resource owner receives its own forced-preference resolver. No test
/// can replace another test's policy, or bypass the production resolver.
@MainActor
struct ManagedCapabilityPolicyGateTests {
    private func policy(_ key: ManagedDevicePolicyKey, disabled: Bool) -> ManagedDevicePolicy {
        ManagedDevicePolicy(releaseDomainDefaults: nil, forcedObject: { _, candidate in
            candidate == key.rawValue ? disabled : nil
        })
    }

    private func remoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "vm:managed-policy-test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "cmux vm-pty-attach --id managed-policy-test",
            skipDaemonBootstrap: true
        )
    }

    @Test(arguments: [false, true])
    func remoteConnectionsHonorForcedPreferences(disabled: Bool) {
        let workspace = Workspace(managedDevicePolicy: policy(.disableRemoteConnections, disabled: disabled))
        #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true) == !disabled)
        #expect((workspace.remoteConfiguration != nil) == !disabled)
    }

    @Test func liftingThePolicyRestoresRemoteConnectionsWithoutARelaunch() throws {
        let suite = "ManagedCapabilityPolicyGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let workspace = Workspace(managedDevicePolicy: resolver)
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        #expect(!workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
    }

    @Test func closedCloudWorkspaceCannotBeRestoredUnderPolicy() {
        let manager = TabManager(createInitialWorkspace: false, managedDevicePolicy: policy(.disableCloud, disabled: true))
        let workspace = Workspace()
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.cloudVM = SessionCloudVMBindingSnapshot(vmID: "policy-blocked", isBase: true)
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: snapshot
        )
        #expect(!manager.restoreClosedWorkspace(entry))
        #expect(manager.tabs.isEmpty)
    }

    @Test func remoteDropUploadFailsClosedUnderThePolicy() throws {
        let workspace = Workspace(managedDevicePolicy: policy(.disableFileTransfer, disabled: true))
        var outcome: Result<[String], Error>?
        workspace.uploadDroppedFilesForRemoteTerminal(
            [URL(fileURLWithPath: "/tmp/managed-policy-payload.txt")],
            operation: TerminalImageTransferOperation()
        ) { outcome = $0 }
        let result = try #require(outcome)
        guard case .failure(let error) = result else {
            Issue.record("upload succeeded under DisableFileTransfer")
            return
        }
        #expect((error as NSError).localizedDescription == ManagedFileTransferPolicy.disabledMessage)
    }

    @Test func detectedSSHUploadRefusesBeforeRunningAnyProcess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("managed-file-transfer-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: fileURL)

        let session = DetectedSSHSession(
            destination: "user@example.com",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        do {
            _ = try session.uploadDroppedFilesSync(
                [fileURL],
                operation: TerminalImageTransferOperation(),
                managedDevicePolicy: policy(.disableFileTransfer, disabled: true)
            )
            Issue.record("detected SSH upload succeeded under DisableFileTransfer")
        } catch {
            #expect((error as NSError).domain == "cmux.managedPolicy.fileTransfer")
            #expect(error.localizedDescription == ManagedFileTransferPolicy.disabledMessage)
        }
    }
}
