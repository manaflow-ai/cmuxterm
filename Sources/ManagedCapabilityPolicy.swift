import CmuxSettings
import Foundation

/// MDM master switches for the capabilities that reach off this Mac.
///
/// Each type is the single authoritative answer to "may cmux do this at all",
/// so every entry point (UI, command palette, menus, CLI, socket, session
/// restore, automation) composes the same check instead of repeating the
/// resolver lookup. All of them default to *allowed*: an unmanaged Mac, and a
/// managed Mac whose profile does not force the key, behave exactly as before.
///
/// The shape mirrors ``MobileRemoteControlPolicy``: a process-wide resolver
/// plus a test-only override, because profile-forced values cannot be
/// simulated without installing a real configuration profile.
enum ManagedRemoteConnectionsPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Test-only override. nonisolated(unsafe): written only by `.serialized`
    /// test suites; the app never mutates it.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    /// Whether a profile forces `DisableRemoteConnections`.
    static var isDisabled: Bool {
        if let overrideForTesting { return overrideForTesting }
        return policy.isEnforced(.disableRemoteConnections)
    }

    static var isEnabled: Bool { !isDisabled }

    /// The message shown wherever a refusal surfaces to the user.
    static var disabledMessage: String {
        String(
            localized: "managedPolicy.remoteConnections.disabled",
            defaultValue: "Remote connections are disabled by your organization."
        )
    }
}

/// MDM master switch for cmux-mediated file transfer.
enum ManagedFileTransferPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Test-only override; see ``ManagedRemoteConnectionsPolicy``.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    /// Whether a profile forces `DisableFileTransfer`.
    static var isDisabled: Bool {
        if let overrideForTesting { return overrideForTesting }
        return policy.isEnforced(.disableFileTransfer)
    }

    static var isEnabled: Bool { !isDisabled }

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.fileTransfer.disabled",
            defaultValue: "File transfer is disabled by your organization."
        )
    }

    /// The failure handed to upload callers. An `NSError` rather than a new
    /// `RemoteDropUploadError` case, so the shared package enum keeps its
    /// exhaustive switches intact.
    static func refusalError() -> NSError {
        NSError(
            domain: "cmux.managedPolicy.fileTransfer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: disabledMessage]
        )
    }
}

/// MDM master switch for cmux-managed Iroh networking.
enum ManagedIrohNetworkingPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Test-only override; see ``ManagedRemoteConnectionsPolicy``.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    /// Whether a profile forces `DisableIrohNetworking`.
    static var isDisabled: Bool {
        if let overrideForTesting { return overrideForTesting }
        return policy.isEnforced(.disableIrohNetworking)
    }

    static var isEnabled: Bool { !isDisabled }

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.irohNetworking.disabled",
            defaultValue: "cmux relay networking is disabled by your organization."
        )
    }
}
