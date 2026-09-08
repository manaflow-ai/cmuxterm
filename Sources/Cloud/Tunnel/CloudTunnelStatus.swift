import AppKit
import Foundation

struct CloudTunnelStatus: Sendable, Equatable {
    let backend: CloudTunnelBackend
    let state: CloudTunnelState
    /// `cmux vpn up` was run explicitly, so the idle policy keeps the tunnel
    /// up until `cmux vpn down` (or quit / sign-out).
    let isPinned: Bool

    /// Why a private-network route cannot work right now on the app-managed
    /// backend, or nil when the tunnel is up.
    var privateRouteBlocker: String? {
        switch state {
        case .up:
            return nil
        case .starting, .stopping:
            return String(
                localized: "cloudTree.link.tunnelStarting",
                defaultValue: "This Mac's tunnel to your Cloud VM network is still starting; the machine reconnects on its own."
            )
        case .awaitingApproval:
            return String(
                localized: "cloudTree.link.tunnelAwaitingApproval",
                defaultValue: "macOS is waiting for you to allow the cmux Cloud Tunnel extension in System Settings › General › Login Items & Extensions."
            )
        case .failed(let message):
            let format = String(
                localized: "cloudTree.link.tunnelFailed",
                defaultValue: "This Mac's tunnel to your Cloud VM network could not start: %@"
            )
            return String(format: format, message)
        case .off:
            return String(
                localized: "cloudTree.link.tunnelOffAppManaged",
                defaultValue: "This Mac's tunnel to your Cloud VM network is down; reopen the machine to start it."
            )
        }
    }
}

/// Where macOS keeps the switch for the cmux Cloud Tunnel extension.
enum CloudTunnelSystemSettings {
    /// System Settings › General › Login Items & Extensions, scrolled to Network
    /// Extensions. The `extensionPointIdentifier` query is what Apple's own
    /// `systemextensionsctl` guidance points at; older releases ignore it and
    /// land on the Login Items pane, which still lists the extension.
    static let networkExtensionsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?extensionPointIdentifier=com.apple.system_extension.network_extension.extension-point"
    )!

    @MainActor
    static func openNetworkExtensions(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        open(networkExtensionsURL)
    }
}
