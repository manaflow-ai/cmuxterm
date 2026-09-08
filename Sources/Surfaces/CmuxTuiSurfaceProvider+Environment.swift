import Foundation

extension CmuxTuiSurfaceProvider {
    /// Delivers `entries` to the machine's `~/.config/cmux/env` over the link — see
    /// `CloudEnvDelivery` for the protocol and why no other channel is acceptable.
    /// Returns what the receiver reported; throws with the receiver's own reason when
    /// it refused, and with an "outdated shim" explanation when the machine does not
    /// know the verb yet.
    func deliverEnvironment(_ entries: [CloudEnvDelivery.Entry]) async throws -> CloudEnvDelivery.Outcome {
        let payload = try CloudEnvDelivery.payload(entries)
        let wire = CloudEnvDelivery.wire(payload)
        if info.remoteWorkspaces?.isEmpty != false { await refresh(force: true) }
        let existingWorkspaceID = info.remoteWorkspaces?.sorted {
            ($0.focused ? 0 : 1, $0.index) < ($1.focused ? 0 : 1, $1.index)
        }.first?.id
        return try await CloudEnvDelivery.withReceiverWorkspace(
            existingWorkspaceID: existingWorkspaceID,
            createWorkspace: { try await self.createEnvironmentReceiverWorkspace() },
            closeWorkspace: { try await self.closeRemoteWorkspace(id: $0) },
            operation: { try await self.deliverEnvironmentWire(wire, workspaceID: $0) }
        )
    }

    private func createEnvironmentReceiverWorkspace() async throws -> String {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let result = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(
            socketPath: connected.socketPath,
            name: "\(CloudEnvDelivery.receiverTitle) \(UUID().uuidString)",
            empty: true
        ))
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let workspaceID = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        return workspaceID
    }

    private func deliverEnvironmentWire(_ wire: Data, workspaceID: String) async throws -> CloudEnvDelivery.Outcome {
        // A terminal in the machine's session, exactly like `surface new-terminal`: it
        // shows in the tree as "cmux env" for the second it lives and is closed below.
        // `--on-exit keep`: the verdict is the receiver's last screen line, which the
        // daemon's default (`close`) would detach before the sender can read it.
        let receiver = try await createTerminal(
            command: CloudEnvDelivery.receiverCommand,
            cwd: nil,
            name: CloudEnvDelivery.receiverTitle,
            remoteWorkspaceID: workspaceID,
            onExit: "keep"
        )
        let terminalID = receiver.id.key
        let outcome: CloudEnvDelivery.Outcome
        do {
            let ready = try await waitForScreen(
                terminalID: terminalID,
                pattern: CloudEnvDelivery.readyMarker,
                timeoutMs: CloudEnvDelivery.readyTimeoutMs
            )
            try CloudEnvDelivery.requireReady(ready, machineID: machineID)
            // Echo is off on the receiver's PTY from here on; the daemon never journals
            // input, so the payload exists on the machine only inside the receiver.
            for chunk in CloudEnvDelivery.chunks(wire) {
                try await writeBytes(terminalID: terminalID, base64: chunk.base64EncodedString())
            }
            let result = try await waitForScreen(
                terminalID: terminalID,
                pattern: CloudEnvDelivery.resultPattern,
                timeoutMs: CloudEnvDelivery.resultTimeoutMs
            )
            outcome = try CloudEnvDelivery.requireOutcome(result)
        } catch {
            // Whatever happened, the receiver must not linger as a pool row.
            _ = try? await Task { @MainActor in try await self.closeTerminal(receiver.id) }.value
            throw error
        }
        try await Task { @MainActor in try await self.closeTerminal(receiver.id) }.value
        return outcome
    }

    /// Raw bytes to the remote terminal's PTY (`terminal write --bytes-base64`).
    func writeBytes(terminalID: String, base64: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.writeBytesArguments(socketPath: connected.socketPath, terminalID: terminalID, base64: base64))
    }
}
