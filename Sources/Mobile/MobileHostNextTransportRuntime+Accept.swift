#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    // MARK: - Accept loop (concurrent serves; hello deadline per connection)

    func startAcceptLoop(endpoint: Endpoint, host: TransportHost, generation gen: UInt64) {
        let sleep = self.sleep
        acceptTask = Task { [weak self] in
            var accepted = 0
            while !Task.isCancelled {
                do {
                    guard let connection = try await IrohSubstrate.acceptOne(endpoint: endpoint)
                    else { break }
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    accepted += 1
                    MobileHostNextTransportRuntime.logger.notice(
                        """
                        host accept-loop connection #\(accepted, privacy: .public) \
                        spawning serve task
                        """)
                    // Serve in a child task so a peer that never sends its hello
                    // (or a long admission) can never wedge subsequent accepts.
                    self.registerServeTask(
                        connection: connection, host: host, number: accepted, generation: gen)
                } catch {
                    guard !Task.isCancelled, !endpoint.isClosed() else { return }
                    MobileHostNextTransportRuntime.logger.error(
                        "host accept-loop transient failure: \(String(describing: error), privacy: .public)")
                    // Avoid a hot loop when a malformed incoming handshake is
                    // rejected before the endpoint itself closes.
                    try? await sleep(.milliseconds(100))
                }
            }
            MobileHostNextTransportRuntime.logger.notice("host accept-loop exit (endpoint closed)")
        }
    }

    private func registerServeTask(
        connection: IrohPeerConnection, host: TransportHost, number: Int, generation gen: UInt64
    ) {
        serveTaskCounter &+= 1
        let id = serveTaskCounter
        let sleep = self.sleep
        let task = Task { [weak self] in
            let served = await Self.serveWithHelloDeadline(
                connection: connection, host: host, number: number, sleep: sleep)
            guard served else {
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            guard let admitted = await host.activeSession(for: connection) else {
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    host serve-task connection #\(number, privacy: .public) \
                    NOT admitted (denied or closed during serve); no bridge
                    """)
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            guard let self, self.generation == gen else {
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            // Count only CONFIRMED admissions (activeSession proved it).
            self.admissions &+= 1
            MobileHostNextTransportRuntime.logger.notice(
                """
                host serve-task connection #\(number, privacy: .public) \
                ADMITTED session=\(admitted.id, privacy: .public) \
                device=\(String(admitted.grant.deviceID.prefix(8)), privacy: .public); \
                starting bridge
                """)
            // Router slice: an admitted connection gets the full legacy
            // application service (control RPC, lane router, server events)
            // bridged over its raw streams. The bridge runs for the session
            // lifetime inside this tracked task, so stop() can cancel it.
            let isCurrent: @Sendable () async -> Bool = { [weak self] in
                let runtime = self
                let enabledAndCurrent = await MainActor.run {
                    guard let runtime else { return false }
                    return runtime.isEnabled && runtime.generation == gen
                }
                guard enabledAndCurrent else { return false }
                return !(await connection.isClosed)
            }
            await MobileHostNextTransportBridge.run(
                connection: connection,
                grant: admitted.grant,
                deviceKey: admitted.deviceKey,
                isCurrent: isCurrent)
            self.serveTasks.removeValue(forKey: id)
        }
        serveTasks[id] = task
    }

    /// Serve one connection under a hello deadline: `host.serve` blocks on
    /// the first control frame, and in the serial design a silent peer
    /// wedged every subsequent accept. Structured race: whichever side
    /// finishes first decides; on deadline the connection is closed INSIDE
    /// the group, which unblocks the pending hello read so the group drains
    /// (uniffi/lane reads do not observe Swift task cancellation, so a
    /// plain cancel would not release the serve child).
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func serveWithHelloDeadline(
        connection: IrohPeerConnection, host: TransportHost, number: Int,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await host.serve(
                    connection: connection, now: Int64(Date().timeIntervalSince1970))
                return true
            }
            group.addTask {
                do {
                    try await sleep(
                        .seconds(NextTransportHostTiming.helloDeadlineSeconds))
                    return false
                } catch {
                    return nil  // sleeper cancelled: serve already finished
                }
            }
            var served = true
            if let first = await group.next(), let outcome = first {
                served = outcome
            }
            if served {
                group.cancelAll()  // stop the timer; the injected scheduler honors cancellation
            } else {
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    host serve-task connection #\(number, privacy: .public) \
                    hello deadline (\(NextTransportHostTiming.helloDeadlineSeconds, privacy: .public)s) \
                    expired; closing connection
                    """)
                await connection.closeAll(reason: nil)
            }
            await group.waitForAll()
            return served
        }
    }

    // MARK: - Deadline race

    /// True when `operation` finishes before the deadline. On timeout the
    /// caller's `onTimeout` hook must abort the underlying operation, after
    /// which both child tasks are cancelled and joined before returning.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func raceDeadline(
        seconds: Int64,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        operation: @escaping @Sendable () async -> Void,
        onTimeout: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                do {
                    try await sleep(.seconds(seconds))
                } catch {
                    return true
                }
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            if !finished {
                await onTimeout?()
            }
            await group.waitForAll()
            return finished
        }
    }

}
#endif
