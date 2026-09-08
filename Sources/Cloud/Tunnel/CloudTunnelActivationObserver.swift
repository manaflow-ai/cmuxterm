import Foundation

/// Brings the app-managed tunnel down when Cloud Machines is turned off while
/// the app runs, so "no tunnel while Cloud Machines is off" holds without a
/// relaunch. Turning it back on needs nothing here: every start asks
/// ``CloudActivationPolicy`` again.
@MainActor
final class CloudTunnelActivationObserver {
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - notificationCenter: Where the Beta Features toggle posts its change.
    ///   - isStartRefused: The policy's answer, read after every change.
    ///   - bringDown: Runs when a change leaves the tunnel refused.
    init(
        notificationCenter: NotificationCenter = .default,
        isStartRefused: @escaping @Sendable () -> Bool,
        bringDown: @escaping @Sendable () async -> Void
    ) {
        observation = Task {
            let changes = notificationCenter.notifications(named: RightSidebarBetaFeatureSettings.didChangeNotification)
            for await _ in changes {
                guard isStartRefused() else { continue }
                await bringDown()
            }
        }
    }

    deinit {
        observation?.cancel()
    }
}
