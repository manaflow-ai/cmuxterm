import Foundation
import Testing
@testable import CmuxNextTransport

@Suite("Remote QUIC closure ownership", .serialized)
struct IrohRemoteClosureTests {
    @Test("remote closure preserves its reason and cancels owned raw delivery",
          .timeLimit(.minutes(1)), arguments: [
            CloseReason.superseded.code, DenialCode.revoked.rawValue,
            CloseReason.grantExpired.code,
          ])
    func remoteClosureCancelsDelivery(code: String) async throws {
        let substrate = IrohSubstrate()
        let server = try await substrate.endpoint(
            identity: .generate(appIdentity: "closure.host", deviceID: "host"),
            minimalLoopback: true)
        let client = try await substrate.endpoint(
            identity: .generate(appIdentity: "closure.client", deviceID: "client"),
            minimalLoopback: true)
        let accepting = Task { try await substrate.acceptOne(endpoint: server) }
        let started = AsyncStream.makeStream(of: Void.self)
        let blocked = AsyncStream.makeStream(of: Void.self)
        defer { blocked.continuation.finish() }
        do {
            let dialer = try await substrate.dial(
                endpoint: client, to: substrate.directAddr(of: server))
            let acceptor = try #require(try await accepting.value)
            await acceptor.onRawStream { _, _ in
                started.continuation.finish()
                for await _ in blocked.stream {}
            }
            _ = try await dialer.openRawStream(preamble: "blocked-handler")
            for await _ in started.stream {}
            let delivery = try #require(await acceptor.rawDeliveryTask)

            await dialer.closeAll(reason: ConnectionTermination(code: code))
            // An unknown named lane returns EOF only after the accept loop
            // has observed the closed stream source and retired its waiters.
            let ended = await acceptor.lane("after-remote-close")
            await #expect(throws: TransportError.pipeClosed) {
                try await ended.send(Frame.dataChunk(seq: 0, data: Data()))
            }
            #expect(await acceptor.termination() == ConnectionTermination(code: code))
            #expect(delivery.isCancelled)
            await acceptor.closeAll()
            #expect(delivery.isCancelled)
            #expect(await acceptor.rawDeliveryTask == nil)

            // Release even the regressed handler, so red assertions do not
            // strand a task or turn this regression into a timeout test.
            blocked.continuation.finish()
            await delivery.value
            try await server.close()
            try await client.close()
        } catch {
            blocked.continuation.finish()
            accepting.cancel()
            try? await server.close()
            try? await client.close()
            _ = await accepting.result
            throw error
        }
    }
}
