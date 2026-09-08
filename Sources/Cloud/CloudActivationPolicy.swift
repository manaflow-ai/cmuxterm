import Foundation

/// What Cloud work this app may start on its own, decided from local state only.
///
/// The Cloud subsystems that would otherwise start at launch ask here first:
/// the cmux-tui registry's fleet polling, and the app-managed tunnel (the
/// system Network Extension). A Mac that never turned on
/// `Settings › Beta Features › Cloud Machines` and never had a machine answers
/// "no" to all of it without a control-plane request and without touching
/// NetworkExtension. Nothing here probes NetworkExtension to decide whether
/// NetworkExtension may be used.
///
/// The inputs are injected closures so the decision is testable without a
/// signed bundle; ``live(defaults:machineCache:browserTunnel:terminalTunnel:)``
/// wires the Beta Features toggle (plus the managed `DisableCloud` policy),
/// the cached machine count and this Mac's tunnel enrollment files, and the
/// browser-role VPN configuration on disk.
struct CloudActivationPolicy: Sendable {
    /// `Settings › Beta Features › Cloud Machines` is on and no managed
    /// profile disables Cloud (``CloudMachinesFeature``).
    let isCloudMachinesEnabled: @Sendable () -> Bool
    /// The account owns at least one machine as far as this Mac knows: the
    /// cached machine list said so, or this Mac enrolled a tunnel role, which
    /// only ever happens for a machine.
    let hasCloudMachine: @Sendable () -> Bool
    /// The app-managed tunnel was configured on this Mac before (the
    /// browser-role WireGuard config exists), so a VPN configuration may be
    /// saved in NetworkExtension preferences.
    let isTunnelConfigured: @Sendable () -> Bool

    /// Fleet polling and links may run: the user opted in, or this Mac used
    /// Cloud before (an update must not strand a fleet the user already has).
    var allowsBackgroundCloudWork: Bool {
        isCloudMachinesEnabled() || hasCloudMachine()
    }

    /// The launch-time tunnel controller may read NetworkExtension preferences
    /// to adopt or stop a tunnel a previous app instance left running. False on
    /// every Mac that never saved a configuration, which is what keeps a fresh
    /// install and an update from 0.64.22 inert.
    var allowsLaunchTimeTunnelAdoption: Bool {
        isTunnelConfigured()
    }

    /// Why a tunnel start is refused right now, or nil when it may proceed:
    /// Cloud Machines must be on, and the account must have a machine.
    func tunnelStartRefusal() -> CloudTunnelStartRefusal? {
        guard isCloudMachinesEnabled() else { return .cloudMachinesOff }
        guard hasCloudMachine() else { return .noCloudMachine }
        return nil
    }

    /// The production policy over this build's defaults and tunnel state files.
    static func live(
        defaults: UserDefaults = .standard,
        machineCache: CloudMachineCache = CloudMachineCache(),
        browserTunnel: VMTunnelManager = VMTunnelManager(purpose: .browser),
        terminalTunnel: VMTunnelManager = VMTunnelManager(purpose: .terminal)
    ) -> CloudActivationPolicy {
        // nonisolated(unsafe): UserDefaults is documented thread-safe but not
        // marked Sendable; the closure only reads through this handle.
        nonisolated(unsafe) let toggleDefaults = defaults
        return CloudActivationPolicy(
            isCloudMachinesEnabled: {
                CloudMachinesFeature.offMainIsEnabled(defaults: toggleDefaults)
            },
            hasCloudMachine: {
                machineCache.hasAnyMachine == true
                    || terminalTunnel.storedDeviceFingerprint() != nil
                    || browserTunnel.writtenConfig() != nil
            },
            isTunnelConfigured: {
                browserTunnel.writtenConfig() != nil
            }
        )
    }
}
