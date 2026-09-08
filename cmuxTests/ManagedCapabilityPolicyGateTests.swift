import CmuxCore
import CmuxRemoteWorkspace
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the MDM capability policies added alongside
/// `DisableCloud`: `DisableRemoteConnections`, `DisableFileTransfer`, and
/// `DisableIrohNetworking`.
///
/// Two properties matter for every one of them. First, **the default is
/// unchanged**: with no profile forcing the key, cmux behaves exactly as an
/// unmanaged install — the first test in each pair asserts the allowed path
/// still works, so a gate that failed closed by accident would fail here.
/// Second, **the gate is authoritative**: it refuses at the one mutation path
/// every entry point funnels through, before any connection or transfer work.
///
/// `.serialized`: these swap process-wide policy overrides.
@MainActor
@Suite(.serialized)
struct ManagedCapabilityPolicyGateTests {
    private func withRemoteConnectionsDisabled(_ disabled: Bool?, _ body: () throws -> Void) rethrows {
        let previous = ManagedRemoteConnectionsPolicy.overrideForTesting
        defer { ManagedRemoteConnectionsPolicy.overrideForTesting = previous }
        ManagedRemoteConnectionsPolicy.overrideForTesting = disabled
        try body()
    }

    private func withFileTransferDisabled(_ disabled: Bool?, _ body: () throws -> Void) rethrows {
        let previous = ManagedFileTransferPolicy.overrideForTesting
        defer { ManagedFileTransferPolicy.overrideForTesting = previous }
        ManagedFileTransferPolicy.overrideForTesting = disabled
        try body()
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

    // MARK: - Defaults

    @Test func everyCapabilityIsAllowedWhenNoProfileForcesTheKey() {
        withRemoteConnectionsDisabled(nil) {
            withFileTransferDisabled(nil) {
                // The test host runs with no configuration profile installed,
                // so this is the shipped default for an unmanaged Mac.
                #expect(ManagedRemoteConnectionsPolicy.isEnabled)
                #expect(ManagedFileTransferPolicy.isEnabled)
                #expect(ManagedIrohNetworkingPolicy.isEnabled)
            }
        }
    }

    // MARK: - DisableRemoteConnections

    @Test func remoteConnectionsConnectNormallyWithoutThePolicy() {
        withRemoteConnectionsDisabled(false) {
            let workspace = Workspace()
            #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
            #expect(workspace.remoteConfiguration != nil)
            #expect(workspace.remoteConnectionState == .connected)
        }
    }

    @Test func thePolicyRefusesTheOneMutationPathThatMakesAWorkspaceRemote() {
        withRemoteConnectionsDisabled(true) {
            let workspace = Workspace()
            // Every entry point — CLI, palette, menus, forks, session restore,
            // automation — reaches remote work through this call, so a refusal
            // here is the whole gate.
            #expect(!workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
            #expect(workspace.remoteConfiguration == nil)
            #expect(workspace.remoteConnectionState != .connected)
        }
    }

    @Test func liftingThePolicyRestoresRemoteConnectionsWithoutARelaunch() {
        let workspace = Workspace()
        withRemoteConnectionsDisabled(true) {
            #expect(!workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
        }
        withRemoteConnectionsDisabled(false) {
            #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
            #expect(workspace.remoteConfiguration != nil)
        }
    }

    // MARK: - DisableFileTransfer

    @Test func remoteDropUploadFailsClosedUnderThePolicy() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("managed-file-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: fileURL)

        try withFileTransferDisabled(true) {
            let workspace = Workspace()
            var outcome: Result<[String], Error>?
            workspace.uploadDroppedFilesForRemoteTerminal(
                [fileURL],
                operation: TerminalImageTransferOperation()
            ) { outcome = $0 }

            let result = try #require(outcome)
            guard case .failure(let error) = result else {
                Issue.record("upload succeeded under DisableFileTransfer")
                return
            }
            #expect((error as NSError).localizedDescription == ManagedFileTransferPolicy.disabledMessage)
        }
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

        final class ProcessProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var invocations: Int { lock.withLock { count } }
            func record() { lock.withLock { count += 1 } }
        }
        let probe = ProcessProbe()
        let previousOverride = DetectedSSHSession.runProcessOverrideForTesting
        defer { DetectedSSHSession.runProcessOverrideForTesting = previousOverride }
        DetectedSSHSession.runProcessOverrideForTesting = { _, _, _, _ in
            probe.record()
            throw CancellationError()
        }

        try withFileTransferDisabled(true) {
            #expect(throws: (any Error).self) {
                _ = try session.uploadDroppedFilesSyncForTesting([fileURL])
            }
            // The refusal happens before ssh/scp is spawned, so a managed Mac
            // never opens a transfer channel it then has to tear down.
            #expect(probe.invocations == 0)
        }
    }

    // MARK: - DisableIrohNetworking

    @Test func irohNetworkingPolicyReportsTheAdministratorsChoice() {
        let previous = ManagedIrohNetworkingPolicy.overrideForTesting
        defer { ManagedIrohNetworkingPolicy.overrideForTesting = previous }

        ManagedIrohNetworkingPolicy.overrideForTesting = true
        #expect(ManagedIrohNetworkingPolicy.isDisabled)
        #expect(!ManagedIrohNetworkingPolicy.isEnabled)
        #expect(!ManagedIrohNetworkingPolicy.disabledMessage.isEmpty)

        ManagedIrohNetworkingPolicy.overrideForTesting = false
        #expect(ManagedIrohNetworkingPolicy.isEnabled)
    }
}
