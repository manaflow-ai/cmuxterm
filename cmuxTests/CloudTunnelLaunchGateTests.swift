import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The launch gate as behavior: a refused start never reaches enrollment or
/// NetworkExtension, the NetworkExtension controller is not even built until
/// the first admitted start, an opt-in flipped while the app runs is honored
/// by the next use, and a Mac with a saved VPN configuration still gets the
/// eager controller so an inherited tunnel is adopted or stopped.
@Suite(.timeLimit(.minutes(2)))
struct CloudTunnelLaunchGateTests {
    private static let extensionID = "com.cmuxterm.app.tests.tunnel"
    private static let networkExtension = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: extensionID)
    private static let use = CloudPrivateNetworkUse(machineID: "vm-1", purpose: .attach)

    /// A gate the test flips mid-scenario, standing in for the Beta Features
    /// toggle and the machine marker.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var refusalValue: CloudTunnelStartRefusal?

        init(_ refusal: CloudTunnelStartRefusal?) {
            refusalValue = refusal
        }

        var refusal: CloudTunnelStartRefusal? {
            get { lock.withLock { refusalValue } }
            set { lock.withLock { refusalValue = newValue } }
        }
    }

    /// Stands in for `NetworkExtensionTunnelController.init`: counts how often
    /// the coordinator's controller seam asks for the real thing.
    @MainActor
    private final class ControllerFactory {
        let controller = FakeTunnelController()
        private(set) var builds: [String] = []

        func make(_ identifier: String = CloudTunnelLaunchGateTests.extensionID) -> any CloudTunnelControlling {
            builds.append(identifier)
            return controller
        }
    }

    private func makeCoordinator(
        controller: any CloudTunnelControlling,
        enroller: FakeTunnelEnroller,
        gate: Gate
    ) -> CloudTunnelCoordinator {
        CloudTunnelCoordinator(
            backend: Self.networkExtension,
            controller: controller,
            enroller: enroller,
            consumers: FakeTunnelConsumers(),
            clock: SidebarTestManualClock(),
            timing: CloudTunnelTiming(),
            refuseStart: { gate.refusal }
        )
    }

    @Test("a refused start touches neither enrollment nor the controller, and says why")
    func refusedStartIsInert() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let gate = Gate(.cloudMachinesOff)
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: gate)

        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await coordinator.beginUp(pin: true)
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requirePrivateNetworkUse(Self.use)
        }
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requestUp(pin: true)
        }

        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned == false)
        #expect(await coordinator.startRefusal() == .cloudMachinesOff)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)

        gate.refusal = .noCloudMachine
        await #expect(throws: CloudTunnelError.noCloudMachine) {
            try await coordinator.requestUp(pin: false)
        }
        #expect(await coordinator.startRefusal() == .noCloudMachine)
        #expect(controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)
    }

    @Test("the NetworkExtension controller is not built until the first admitted start, and a runtime opt-in needs no relaunch")
    @MainActor
    func controllerIsBuiltOnlyForAnAdmittedStart() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let enroller = FakeTunnelEnroller()
        let gate = Gate(.cloudMachinesOff)
        let coordinator = makeCoordinator(controller: deferred, enroller: enroller, gate: gate)

        // Everything a launch, a quit, a sign-out, and `cmux vpn down|status|revoke`
        // do on a Mac that never opted in: none of it builds the controller.
        _ = await coordinator.status()
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await coordinator.requestDown()
        await coordinator.accessDidEnd()
        try await coordinator.revoke()
        coordinator.appWillTerminate()
        #expect(factory.builds.isEmpty)
        #expect(deferred.buildCount == 0)
        #expect(deferred.builtController == nil)
        #expect(factory.controller.calls.isEmpty)
        #expect(enroller.enrollCount == 0)
        #expect(await coordinator.state == .off)

        // The user turns Cloud Machines on and has a machine: the next use
        // builds the controller and brings the tunnel up.
        gate.refusal = nil
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await coordinator.state == .up)
        #expect(factory.builds == [Self.extensionID])
        #expect(deferred.buildCount == 1)
        #expect(factory.controller.calls == ["install", "start"])
        #expect(enroller.enrollCount == 1)

        // Later uses and the teardown paths reuse the one controller.
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)
        #expect(factory.builds.count == 1)
        #expect(factory.controller.calls == ["install", "start", "stop"])
    }

    @Test("turning Cloud Machines off after a start refuses the next use; the existing tunnel is brought down by the observer's request")
    @MainActor
    func runtimeOptOutIsHonored() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let enroller = FakeTunnelEnroller()
        let gate = Gate(nil)
        let coordinator = makeCoordinator(controller: deferred, enroller: enroller, gate: gate)
        try await coordinator.requestUp(pin: true)
        #expect(await coordinator.state == .up)

        gate.refusal = .cloudMachinesOff
        // What `CloudTunnelActivationObserver` does on the toggle change.
        await coordinator.requestDown()
        #expect(await coordinator.state == .off)
        #expect(await coordinator.isPinned == false)
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        await #expect(throws: CloudTunnelError.cloudMachinesOff) {
            try await coordinator.requirePrivateNetworkUse(Self.use)
        }
        #expect(await coordinator.state == .off)
        #expect(factory.controller.calls == ["install", "start", "stop"])
        #expect(enroller.enrollCount == 1)
    }

    @Test("launch composition: a saved VPN configuration gets the eager controller, otherwise construction waits; an unavailable build is inert")
    @MainActor
    func launchCompositionDefersWithoutASavedConfiguration() {
        let factory = ControllerFactory()
        let fresh = CloudActivationPolicy(
            isCloudMachinesEnabled: { false },
            hasCloudMachine: { false },
            isTunnelConfigured: { false }
        )
        let deferred = CloudTunnelCoordinator.liveController(for: Self.networkExtension, activation: fresh) { identifier in
            factory.make(identifier)
        }
        #expect(deferred is CloudTunnelDeferredController)
        #expect(factory.builds.isEmpty)

        let inherited = CloudActivationPolicy(
            isCloudMachinesEnabled: { true },
            hasCloudMachine: { true },
            isTunnelConfigured: { true }
        )
        let eager = CloudTunnelCoordinator.liveController(for: Self.networkExtension, activation: inherited) { identifier in
            factory.make(identifier)
        }
        #expect(eager is FakeTunnelController)
        #expect(factory.builds == [Self.extensionID])

        let unavailable = CloudTunnelCoordinator.liveController(
            for: .unavailable(.entitlementMissing),
            activation: inherited
        ) { identifier in
            factory.make(identifier)
        }
        #expect(unavailable is CloudTunnelInertController)
        #expect(factory.builds == [Self.extensionID])
    }

    @Test("with the eager controller an inherited tunnel is adopted by the first use and stopped by down without enrolling")
    func eagerControllerAdoptsAndStopsAnInheritedTunnel() async {
        let controller = FakeTunnelController()
        controller.currentStatusValue = .connected
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller, gate: Gate(nil))

        // Quit or sign-out on a Mac whose previous session left the link up.
        await coordinator.requestDown()
        #expect(controller.calls == ["stop"])
        #expect(enroller.enrollCount == 0)

        controller.currentStatusValue = .connected
        await coordinator.prepareForPrivateNetworkUse(Self.use)
        #expect(await coordinator.state == .up)
        #expect(controller.calls == ["stop", "install"])
    }

    @Test("the deferred controller is inert before its first install and forwards link status after it")
    @MainActor
    func deferredControllerForwardsAfterBuild() async throws {
        let factory = ControllerFactory()
        let deferred = CloudTunnelDeferredController { factory.make() }
        let updates = deferred.statusUpdates
        await Task.yield()

        #expect(await deferred.currentStatus() == .invalid)
        try await deferred.stop()
        try await deferred.remove()
        deferred.stopForTermination()
        await #expect(throws: CloudTunnelError.configurationNotInstalled) {
            try await deferred.start()
        }
        #expect(factory.builds.isEmpty)
        #expect(factory.controller.calls.isEmpty)

        let configuration = CloudTunnelProviderConfiguration(
            wgQuickConfig: FakeTunnelEnroller.config,
            serverAddress: "vpn.example.com:51820",
            localizedDescription: "cmux Cloud"
        )
        try await deferred.install(configuration) {}
        #expect(factory.builds.count == 1)
        #expect(factory.controller.calls == ["install"])
        #expect(await deferred.currentStatus() == .disconnected)

        factory.controller.emit(.connecting)
        factory.controller.emit(.connected)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .connecting)
        #expect(await iterator.next() == .connected)

        try await deferred.start()
        try await deferred.stop()
        try await deferred.remove()
        deferred.stopForTermination()
        #expect(factory.controller.calls == ["install", "start", "stop", "remove", "stopForTermination"])
        #expect(factory.builds.count == 1)
    }
}
