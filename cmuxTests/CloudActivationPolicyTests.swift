import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The one launch-time decision for Cloud, as behavior: a Mac that never opted
/// in and never had a machine is inert (no fleet polling, no tunnel start, no
/// NetworkExtension preferences read); the Beta Features toggle plus a machine
/// admits the tunnel; prior Cloud use on this Mac keeps its fleet alive but
/// never opens the tunnel without the toggle.
@Suite
struct CloudActivationPolicyTests {
    private func policy(enabled: Bool, machine: Bool, configured: Bool) -> CloudActivationPolicy {
        CloudActivationPolicy(
            isCloudMachinesEnabled: { enabled },
            hasCloudMachine: { machine },
            isTunnelConfigured: { configured }
        )
    }

    @Test("a fresh install is inert: no background work, no adoption, every start refused")
    func freshInstallIsInert() {
        let policy = policy(enabled: false, machine: false, configured: false)
        #expect(policy.allowsBackgroundCloudWork == false)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("the toggle alone is not enough: the account needs a machine")
    func toggleWithoutMachine() {
        let policy = policy(enabled: true, machine: false, configured: false)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)
    }

    @Test("the toggle plus a machine admits the tunnel")
    func toggleWithMachine() {
        let policy = policy(enabled: true, machine: true, configured: false)
        #expect(policy.tunnelStartRefusal() == nil)
        #expect(policy.allowsBackgroundCloudWork)
    }

    @Test("prior Cloud use keeps the fleet alive and lets an inherited tunnel be adopted, but a start still needs the toggle")
    func priorUseWithoutToggle() {
        let policy = policy(enabled: false, machine: true, configured: true)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.allowsLaunchTimeTunnelAdoption)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("refusals map to user-presentable errors and stable wire tokens")
    func refusalTokens() {
        #expect(CloudTunnelStartRefusal.cloudMachinesOff.rawValue == "cloud-machines-off")
        #expect(CloudTunnelStartRefusal.noCloudMachine.rawValue == "no-cloud-machine")
        #expect(CloudTunnelStartRefusal.cloudMachinesOff.error == .cloudMachinesOff)
        #expect(CloudTunnelStartRefusal.noCloudMachine.error == .noCloudMachine)
        #expect(!CloudTunnelError.cloudMachinesOff.description.isEmpty)
        #expect(!CloudTunnelError.noCloudMachine.description.isEmpty)
        #expect(CloudTunnelError.cloudMachinesOff.description != CloudTunnelError.noCloudMachine.description)
    }

    // MARK: - The live inputs: defaults, the machine cache, and the tunnel files

    private struct LiveHarness {
        let suiteName: String
        let defaults: UserDefaults
        let home: URL
        let cache: CloudMachineCache
        let browser: VMTunnelManager
        let terminal: VMTunnelManager
        let policy: CloudActivationPolicy

        init() throws {
            suiteName = "cmux.cloud.activation.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-activation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            cache = CloudMachineCache(defaults: defaults)
            browser = VMTunnelManager(
                home: home,
                interfaceName: "cmux-t",
                purpose: .browser,
                bundleIdentifier: "com.cmuxterm.app.tests"
            )
            terminal = VMTunnelManager(
                home: home,
                interfaceName: "cmux-t",
                purpose: .terminal,
                bundleIdentifier: "com.cmuxterm.app.tests"
            )
            policy = CloudActivationPolicy.live(
                defaults: defaults,
                machineCache: cache,
                browserTunnel: browser,
                terminalTunnel: terminal
            )
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: home)
        }

        func turnCloudMachines(on enabled: Bool) {
            defaults.set(enabled, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        }

        /// What a previous opted-in session leaves behind: the browser-role config.
        func saveBrowserConfig() throws {
            let url = browser.configURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "[Interface]\nPrivateKey = test\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test("live inputs: a fresh install answers no to everything, the toggle and a listed machine open the gate, sign-out closes it")
    func liveInputsFollowDefaultsAndFiles() throws {
        let harness = try LiveHarness()
        defer { harness.tearDown() }
        let policy = harness.policy

        #expect(policy.allowsBackgroundCloudWork == false)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)

        harness.turnCloudMachines(on: true)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)

        // The machine list came back empty, then a machine was created.
        harness.cache.record(hasAnyMachine: false)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)
        harness.cache.record(hasAnyMachine: true)
        #expect(policy.tunnelStartRefusal() == nil)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)

        // Sign-out clears the cache: the next account starts over.
        harness.cache.clear()
        #expect(harness.cache.hasAnyMachine == nil)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)

        harness.turnCloudMachines(on: false)
        #expect(policy.allowsBackgroundCloudWork == false)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("live inputs: this Mac's own enrollment counts as having a machine; a saved VPN configuration allows launch-time adoption")
    func liveInputsHonorEnrollmentFiles() throws {
        let harness = try LiveHarness()
        defer { harness.tearDown() }
        let policy = harness.policy
        harness.turnCloudMachines(on: true)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)

        // The user-space hub enrolled the terminal role (a link to a machine).
        _ = try harness.terminal.deviceFingerprint()
        #expect(policy.tunnelStartRefusal() == nil)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        harness.terminal.removeLocalCredentials()
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)

        // A previous session saved the browser-role config.
        try harness.saveBrowserConfig()
        #expect(policy.allowsLaunchTimeTunnelAdoption)
        #expect(policy.tunnelStartRefusal() == nil)
        harness.turnCloudMachines(on: false)
        // Adoption (cleanup) stays possible; a new start does not.
        #expect(policy.allowsLaunchTimeTunnelAdoption)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
        harness.browser.removeLocalCredentials()
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
    }

    @Test("the machine cache is unknown until the first list and forgets on clear")
    func machineCacheLifecycle() throws {
        let suiteName = "cmux.cloud.machineCache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = CloudMachineCache(defaults: defaults)
        #expect(cache.hasAnyMachine == nil)
        cache.record(hasAnyMachine: true)
        #expect(cache.hasAnyMachine == true)
        cache.record(hasAnyMachine: false)
        #expect(cache.hasAnyMachine == false)
        cache.clear()
        #expect(cache.hasAnyMachine == nil)
    }

    @Test("Cloud Machines is off by default, on only through the Beta Features toggle, and never on under a managed DisableCloud")
    func cloudMachinesGateIsTheBetaToggle() throws {
        let suiteName = "cmux.cloud.feature.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unmanaged = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let managedOff = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, key in
            key == ManagedDevicePolicyKey.disableCloud.rawValue ? true : nil
        })

        #expect(CloudMachinesFeature.localOptIn(defaults: defaults) == false)
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: unmanaged) == false)

        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: unmanaged))
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: managedOff) == false)

        defaults.set(false, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: unmanaged) == false)
    }
}
