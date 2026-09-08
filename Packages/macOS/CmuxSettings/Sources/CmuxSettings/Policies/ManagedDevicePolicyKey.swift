import Foundation

/// A device-management policy cmux honors when an administrator forces it
/// through a macOS configuration profile (MDM "Custom Settings" payload).
///
/// The raw value is the preference key an administrator sets in the
/// ``ManagedDevicePolicy/releasePayloadDomain`` preference domain. Policy
/// keys are deliberately separate from the user-facing settings catalog:
/// a managed policy is tier-0 — it wins over environment variables, user
/// `UserDefaults`, `cmux.json` imports, and built-in defaults — and it can
/// never be changed from inside the app.
public enum ManagedDevicePolicyKey: String, CaseIterable, Sendable {
    /// Disables every embedded-browser surface: browser panes and tabs,
    /// terminal-link interception, and browser creation from automation,
    /// layouts, and session restore.
    case disableEmbeddedBrowser = "DisableEmbeddedBrowser"

    /// Disables the Mac acting as a remote view/control host for the cmux
    /// iOS companion app: the Iroh host runtime, the legacy TCP pairing
    /// listener, connection admission, and device pairing.
    case disableRemoteControl = "DisableRemoteControl"

    /// Disables cmux Cloud Machines and the cmux-managed private network. This
    /// is a tier-0 administrator gate: the sidebar, Settings, palette, session
    /// restore, the surface registry, Cloud VM service calls, the tunnel, and
    /// CLI/socket commands all fail closed while it is enforced.
    case disableCloud = "DisableCloud"

    /// Disables cmux-created remote connections: SSH, Mosh, remote tmux, and
    /// the remote registry, from every entry point (CLI, palette, menus,
    /// session restore, automation). Cloud Machines attach over the same
    /// mechanism, so this key gates them too; ``disableCloud`` remains the key
    /// for disabling Cloud as a product. Terminals on this Mac are unaffected,
    /// and a user's own `ssh` typed into a shell is out of scope by design.
    case disableRemoteConnections = "DisableRemoteConnections"

    /// Disables cmux-mediated file transfer: drag-and-drop and pasted-image
    /// uploads into remote terminals, the configured custom upload command,
    /// and Cloud VM push/pull. Local drops into local terminals still work,
    /// and a user's own `scp` in a shell is out of scope by design.
    case disableFileTransfer = "DisableFileTransfer"

    /// Disables cmux-managed Iroh networking: the host runtime, its relay
    /// traffic, and the client-side connectivity subscriber. Local terminal
    /// work is unaffected. ``disableRemoteControl`` disables the Mac as an
    /// iOS remote-control host specifically; this key disables the Iroh
    /// transport itself, including the paths that are not remote control.
    case disableIrohNetworking = "DisableIrohNetworking"

    /// Restricts embedded-browser top-level navigations to the administrator's
    /// URL patterns. An empty forced array denies every external web origin
    /// while preserving local `file:` documents opened through cmux's trusted
    /// app-owned path and cmux-owned internal documents.
    case browserURLAllowlist = "BrowserURLAllowlist"
}
