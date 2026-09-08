import Foundation

/// Owns every loopback port forward the app has open, keyed by Cloud machine
/// and VM port, so one (machine, port) maps to one stable local port for as
/// long as the machine is registered. Forwards close when the machine leaves
/// the fleet, on sign-out, and with the process.
actor CloudHubPortForwarder {
    struct Key: Hashable, Sendable {
        let machineID: String
        let port: Int
    }

    private let dialer: any CloudHubDialing
    private var forwards: [Key: CloudLoopbackPortForward] = [:]
    private var starting: [Key: Task<CloudLoopbackPortForward, any Error>] = [:]

    init(dialer: any CloudHubDialing) {
        self.dialer = dialer
    }

    /// The forward for `target.port` on `machineID`, started on first use.
    /// Concurrent first uses share one start and the same bookkeeping; a
    /// changed private address retargets the existing listener so open panes
    /// keep their URL; a listener that died is torn down before it is replaced.
    func forward(machineID: String, to target: CloudPortForwardTarget) async throws -> CloudLoopbackPortForward {
        let key = Key(machineID: machineID, port: target.port)
        if let existing = forwards[key] {
            if await existing.isListening {
                await Self.retargetIfNeeded(existing, to: target)
                return existing
            }
            forwards[key] = nil
            await existing.stop()
        }
        let task: Task<CloudLoopbackPortForward, any Error>
        if let inFlight = starting[key] {
            task = inFlight
        } else {
            let dialer = self.dialer
            task = Task { () throws -> CloudLoopbackPortForward in
                let forward = try CloudLoopbackPortForward(target: target, dialer: dialer)
                try await forward.start()
                return forward
            }
            starting[key] = task
        }
        let forward: CloudLoopbackPortForward
        do {
            forward = try await task.value
        } catch {
            if starting[key] == task { starting[key] = nil }
            throw error
        }
        if let stored = forwards[key], stored === forward {
            // Another waiter on the same start finished the bookkeeping first.
            await Self.retargetIfNeeded(stored, to: target)
            return stored
        }
        guard starting[key] == task else {
            // Closed while starting: nothing may keep a listener for a machine
            // that left the fleet, and no waiter may receive a stopped one.
            await forward.stop()
            throw CancellationError()
        }
        starting[key] = nil
        forwards[key] = forward
        await Self.retargetIfNeeded(forward, to: target)
        return forward
    }

    private static func retargetIfNeeded(_ forward: CloudLoopbackPortForward, to target: CloudPortForwardTarget) async {
        if await forward.target != target {
            await forward.retarget(target)
        }
    }

    /// The local port already forwarding to `port` on `machineID`, if any.
    func localPort(machineID: String, port: Int) async -> UInt16? {
        await forwards[Key(machineID: machineID, port: port)]?.localPort
    }

    var count: Int { forwards.count }

    func close(machineID: String, port: Int) async {
        await close(Key(machineID: machineID, port: port))
    }

    /// Closes every forward on a machine (it left the fleet or was deleted).
    func close(machineID: String) async {
        for key in Set(forwards.keys).union(starting.keys) where key.machineID == machineID {
            await close(key)
        }
    }

    func closeAll() async {
        for key in Set(forwards.keys).union(starting.keys) {
            await close(key)
        }
    }

    private func close(_ key: Key) async {
        starting[key]?.cancel()
        starting[key] = nil
        if let forward = forwards.removeValue(forKey: key) {
            await forward.stop()
        }
    }
}
