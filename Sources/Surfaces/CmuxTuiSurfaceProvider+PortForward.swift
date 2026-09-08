import Foundation

/// The Ports and Desktop rows' panes: every route goes through
/// ``CloudPortRoutePlan``, and a machine with a private address is reached
/// over the user-space WireGuard hub on a loopback forward. Nothing here asks
/// for the Network Extension.
extension CmuxTuiSurfaceProvider {
    /// Creates the browser pane for a port or desktop row at once (showing the
    /// connecting placeholder) and navigates it when its route is ready. The
    /// forward exists before this returns, so `localPortURL(port:)` answers
    /// immediately afterwards.
    func materializeBrowserPane(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> (workspaceID: UUID, panelID: UUID) {
        let desktop = resource.kind == .display
        let plan = CloudPortRoutePlan.plan(
            resource: resource,
            privateAddress: info.privateAddress,
            supportsControlPlanePreviews: capabilities.ports
        )
        switch plan {
        case .unsupported(let reason):
            throw SurfaceCatalogError.unsupported(reason)
        case .hubForward(let target, let remoteURL):
            let forward = try await hubForward(to: target)
            guard let localURL = CloudPortRoutePlan.localURL(rewriting: remoteURL, toLoopbackPort: await forward.localPort) else {
                throw ProviderError.localForwardURLUnavailable
            }
            let label = Self.paneLabel(machineID: machineID, port: target.port, desktop: desktop)
            let pane = try Self.makeConnectingPane(label: label, at: destination, focus: focus)
            let machineWasAwake = isAwake
            // A provider that is stopped or replaced while this runs must not
            // touch the pane its successor now owns.
            let generation = currentLifecycleGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if !machineWasAwake {
                        // Waking a paused machine is an explicit management
                        // operation. The returned public URL is ignored; the
                        // pane keeps the private route.
                        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                        _ = try await client.openPort(id: self.machineID, port: target.port)
                    }
                    // Start the hub now so a hub that cannot come up is explained
                    // in the pane instead of surfacing as a browser error page.
                    try await forward.warmUpHub()
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    SurfacePaneFactory.navigate(panelID: pane.panelID, in: pane.workspaceID, to: localURL)
                } catch {
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    Self.showFailure(label: label, error: error, pane: pane)
                }
            }
            return pane
        case .controlPlanePreview(let port):
            let label = Self.paneLabel(machineID: machineID, port: port, desktop: desktop)
            let pane = try Self.makeConnectingPane(label: label, at: destination, focus: focus)
            let generation = currentLifecycleGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                    let endpoint = try await client.openPort(id: self.machineID, port: port)
                    guard let url = URL(string: endpoint.openUrl) else { throw ProviderError.badURL(endpoint.openUrl) }
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    SurfacePaneFactory.navigate(panelID: pane.panelID, in: pane.workspaceID, to: url)
                } catch {
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    Self.showFailure(label: label, error: error, pane: pane)
                }
            }
            return pane
        }
    }

    /// The loopback URL that reaches `port` on this machine from any app on
    /// this Mac (Copy Link, `vm.port_open`), starting the forward if needed.
    /// Nil when the machine has no private address, so its ports are only
    /// reachable through the control plane's preview URL; throws only when a
    /// forward should exist and could not be made.
    func localPortURL(port: Int) async throws -> String? {
        let plan = CloudPortRoutePlan.plan(
            resource: CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port),
            privateAddress: info.privateAddress,
            supportsControlPlanePreviews: capabilities.ports
        )
        guard case .hubForward(let target, _) = plan else { return nil }
        return try await hubForward(to: target).localURLString
    }

    private func hubForward(to target: CloudPortForwardTarget) async throws -> CloudLoopbackPortForward {
        guard let portForwards else { throw ProviderError.hubUnavailable }
        return try await portForwards.forward(machineID: machineID, to: target)
    }

    private static func makeConnectingPane(
        label: String,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let pane = try SurfacePaneFactory.makeBrowserPane(url: SurfacePaneFactory.blankURL, at: destination, focus: focus)
        SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.connecting(label), panelID: pane.panelID, in: pane.workspaceID)
        return pane
    }

    private static func showFailure(label: String, error: any Error, pane: (workspaceID: UUID, panelID: UUID)) {
        let text = CloudMachineLink.errorText(error)
        SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.failed(label, error: text), panelID: pane.panelID, in: pane.workspaceID)
        #if DEBUG
        cmuxDebugLog("cloud.provider.endpointFailed label=\(label) error=\(String(reflecting: error))")
        #endif
    }
}
