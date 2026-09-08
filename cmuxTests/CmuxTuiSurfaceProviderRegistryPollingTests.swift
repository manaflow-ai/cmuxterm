import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The registry's periodic fleet read is the only Cloud API traffic an idle
/// app makes, so it must follow the activation policy: never scheduled for a
/// Mac that has not opted in, started when the Beta Features toggle turns on,
/// and cancelled again when it turns off, all without a relaunch.
@Suite(.timeLimit(.minutes(1)))
struct CmuxTuiSurfaceProviderRegistryPollingTests {
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isOn: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @Test("fleet polling starts only when background Cloud work is allowed, and follows the toggle at runtime")
    @MainActor
    func pollingFollowsTheActivationPolicy() async {
        let allowed = Switch()
        let center = NotificationCenter.default
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { allowed.isOn }
        )

        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling == false)

        // Settings › Beta Features › Cloud Machines turned on.
        allowed.isOn = true
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { registry.isPolling })

        // A repeated change is idempotent.
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { registry.isPolling })

        // Turned off again: the poll is cancelled.
        allowed.isOn = false
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        #expect(await waitUntil { !registry.isPolling })
    }

    @Test("a registry that is allowed background work polls from start")
    @MainActor
    func allowedRegistryPollsImmediately() async {
        let allowed = Switch()
        allowed.isOn = true
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            wireGuardHub: nil,
            allowsBackgroundWork: { allowed.isOn }
        )
        registry.start(catalog: SurfaceCatalog())
        #expect(registry.isPolling)

        allowed.isOn = false
        registry.syncPollingToActivationPolicy()
        #expect(registry.isPolling == false)
    }
}
