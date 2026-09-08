import Foundation

/// Why ``CloudActivationPolicy`` refuses to start the app-managed tunnel.
/// Raw values are stable tokens for `vm.tunnel_*` payloads and `cmux vpn`.
enum CloudTunnelStartRefusal: String, Sendable, Equatable {
    /// `Settings › Beta Features › Cloud Machines` is off, or a managed
    /// profile disables Cloud.
    case cloudMachinesOff = "cloud-machines-off"
    /// The account has no Cloud machine yet, so there is nothing to reach.
    case noCloudMachine = "no-cloud-machine"

    /// The error the coordinator and the socket verbs report for this refusal.
    var error: CloudTunnelError {
        switch self {
        case .cloudMachinesOff: return .cloudMachinesOff
        case .noCloudMachine: return .noCloudMachine
        }
    }
}
