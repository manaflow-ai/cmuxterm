import Foundation

/// What Cloud work this app may start on its own, decided from local state.
///
/// The Cloud subsystems that would otherwise start at launch ask here first:
/// the cmux-tui registry's fleet polling, and the app-managed tunnel (the
/// system Network Extension). A Mac that never turned on
/// `Settings › Beta Features › Cloud Machines` and never had a machine answers
/// "no" to all of it without a control-plane request and without touching
/// NetworkExtension. Nothing here probes NetworkExtension to decide whether
/// NetworkExtension may be used.
///
/// The one thing local state cannot always answer is whether the account has
/// a machine: the cached marker is cleared on sign-out, absent on a fresh
/// opt-in, and stale once a machine is created elsewhere. Launch-time
/// decisions treat anything but a known machine as "no"; an explicit Cloud
/// use (browser open, `cmux vpn up`) asks the control plane through
/// `resolveCloudMachine` (a fleet list, which also refills the marker).
///
/// The inputs are injected closures so the decision is testable without a
/// signed bundle; ``live(defaults:machineCache:browserTunnel:terminalTunnel:resolveCloudMachine:)``
/// wires the Beta Features toggle (plus the managed `DisableCloud` policy),
/// the cached machine count and this Mac's tunnel enrollment files, the
/// browser-role VPN configuration on disk, and ``VMClient`` for resolution.
struct CloudActivationPolicy: Sendable {
    /// `Settings › Beta Features › Cloud Machines` is on and no managed
    /// profile disables Cloud (``CloudMachinesFeature``).
    let isCloudMachinesEnabled: @Sendable () -> Bool
    /// Whether the account owns at least one machine, as far as this Mac
    /// knows: the cached machine list said so (true or false), or this Mac
    /// enrolled a tunnel role, which only ever happens for a machine (true).
    /// `nil` when nothing local can say (never listed, or cleared by sign-out).
    let hasCloudMachine: @Sendable () -> Bool?
    /// The app-managed tunnel was configured on this Mac before (the
    /// browser-role WireGuard config exists), so a VPN configuration may be
    /// saved in NetworkExtension preferences.
    let isTunnelConfigured: @Sendable () -> Bool
    /// Asks the control plane whether the account has a machine; `nil` when it
    /// cannot answer (signed out, offline). Used only when ``hasCloudMachine``
    /// cannot confirm one, and only from an explicit Cloud use, never at launch.
    let resolveCloudMachine: @Sendable () async -> Bool?

    /// Fleet polling and links may run: the user opted in, or this Mac is
    /// known to have used Cloud (an update must not strand a fleet the user
    /// already has). An unknown machine count does not open this.
    var allowsBackgroundCloudWork: Bool {
        isCloudMachinesEnabled() || hasCloudMachine() == true
    }

    /// The launch-time tunnel controller may read NetworkExtension preferences
    /// to adopt or stop a tunnel a previous app instance left running. False on
    /// every Mac that never saved a configuration, which is what keeps a fresh
    /// install and an update from 0.64.22 inert.
    var allowsLaunchTimeTunnelAdoption: Bool {
        isTunnelConfigured()
    }

    /// Why a tunnel start is refused as far as local state knows, or nil.
    /// Cloud Machines must be on; a machine count known to be zero refuses;
    /// an unknown count does not (``resolvedTunnelStartRefusal()`` settles it).
    func tunnelStartRefusal() -> CloudTunnelStartRefusal? {
        guard isCloudMachinesEnabled() else { return .cloudMachinesOff }
        return hasCloudMachine() == false ? .noCloudMachine : nil
    }

    /// ``tunnelStartRefusal()`` settled against the control plane whenever
    /// local state cannot confirm a machine (unknown, or last seen as zero: a
    /// machine created on the web must not wait for the next fleet poll). An
    /// answer it cannot get (signed out, offline) keeps the local one; when
    /// that is unknown, the start proceeds and enrollment reports why it
    /// cannot, before NetworkExtension is touched.
    func resolvedTunnelStartRefusal() async -> CloudTunnelStartRefusal? {
        guard isCloudMachinesEnabled() else { return .cloudMachinesOff }
        let known = hasCloudMachine()
        if known == true { return nil }
        switch await resolveCloudMachine() {
        case .some(true):
            return nil
        case .some(false):
            return .noCloudMachine
        case nil:
            return known == false ? .noCloudMachine : nil
        }
    }

    /// Both answers, for ``CloudTunnelCoordinator``.
    var tunnelAdmission: CloudTunnelAdmission {
        CloudTunnelAdmission(
            knownRefusal: { tunnelStartRefusal() },
            resolvedRefusal: { await resolvedTunnelStartRefusal() }
        )
    }

    /// The production policy over this build's defaults, tunnel state files,
    /// and the signed-in ``VMClient``.
    static func live(
        defaults: UserDefaults = .standard,
        machineCache: CloudMachineCache = CloudMachineCache(),
        browserTunnel: VMTunnelManager = VMTunnelManager(purpose: .browser),
        terminalTunnel: VMTunnelManager = VMTunnelManager(purpose: .terminal),
        resolveCloudMachine: @escaping @Sendable () async -> Bool? = { await listedFleetHasMachine() }
    ) -> CloudActivationPolicy {
        // nonisolated(unsafe): UserDefaults is documented thread-safe but not
        // marked Sendable; the closure only reads through this handle.
        nonisolated(unsafe) let toggleDefaults = defaults
        return CloudActivationPolicy(
            isCloudMachinesEnabled: {
                CloudMachinesFeature.offMainIsEnabled(defaults: toggleDefaults)
            },
            hasCloudMachine: {
                if let cached = machineCache.hasAnyMachine { return cached }
                if terminalTunnel.storedDeviceFingerprint() != nil || browserTunnel.writtenConfig() != nil {
                    return true
                }
                return nil
            },
            isTunnelConfigured: {
                browserTunnel.writtenConfig() != nil
            },
            resolveCloudMachine: resolveCloudMachine
        )
    }

    /// One fleet list through the shared client; it refills
    /// ``CloudMachineCache`` as a side effect. `nil` when there is no client
    /// (not signed in) or the request fails.
    static func listedFleetHasMachine() async -> Bool? {
        let client: VMClient? = await MainActor.run { VMClient.shared }
        guard let client, let page = try? await client.listPage() else { return nil }
        return !page.vms.isEmpty
    }
}
