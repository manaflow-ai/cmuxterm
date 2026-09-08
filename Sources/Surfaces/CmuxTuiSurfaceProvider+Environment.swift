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
        return try await CloudEnvDelivery.withReceiverWorkspace(
            createWorkspace: { try await self.createEnvironmentReceiverWorkspace() },
            closeWorkspace: { try await self.removeEnvironmentReceiverWorkspace($0) },
            operation: { try await self.deliverEnvironmentWire(wire, workspaceID: $0) }
        )
    }

    private func removeEnvironmentReceiverWorkspace(_ workspaceID: String) async throws {
        guard await refresh(force: true) else {
            throw CloudEnvDelivery.DeliveryError.workspaceCleanupFailed(workspaceID)
        }
        let terminals = catalog.snapshot.resources(on: machine).filter {
            $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
        }
        try await CloudEnvDelivery.removeReceiverResources(
            terminalIDs: terminals.map { $0.id.key },
            closeTerminal: { terminalID in
                do {
                    try await self.closeTerminal(SurfaceResourceID(machine: self.machine, kind: .terminal, key: terminalID))
                } catch {
                    guard Self.isSelectorNotFound(error) else { throw error }
                }
            },
            closeWorkspace: { try await self.closeRemoteWorkspace(id: workspaceID) }
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
            return try CloudEnvDelivery.requireOutcome(result)
        }
    }

    /// Raw bytes to the remote terminal's PTY (`terminal write --bytes-base64`).
    func writeBytes(terminalID: String, base64: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.writeBytesArguments(socketPath: connected.socketPath, terminalID: terminalID, base64: base64))
    }
}
