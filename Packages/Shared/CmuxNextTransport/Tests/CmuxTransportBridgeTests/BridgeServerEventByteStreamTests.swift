import CmuxIrohTransport
import CmuxNextTransportBridge
import Foundation
import Testing

@Suite("Bridge server-event terminal outcomes")
struct BridgeServerEventByteStreamTests {
    @Test("Receive failure sends the failure stop code")
    func readFailure() async throws {
        let source = ServerEventReceiveFixture(chunks: [], fails: true)
        do {
            for try await _ in BridgeServerEventByteStream().bytes(from: source) {}
            Issue.record("Expected the read error")
        } catch is ServerEventReceiveFixture.Failure {}
        #expect(await source.firstStop() == 1)
    }

    @Test("Clean EOF preserves bytes and sends the clean stop code")
    func cleanEOF() async throws {
        let chunks = [Data([1, 2]), Data([3, 4])]
        let source = ServerEventReceiveFixture(chunks: chunks, fails: false)
        var received: [Data] = []
        for try await chunk in BridgeServerEventByteStream().bytes(from: source) {
            received.append(chunk)
        }
        #expect(received == chunks)
        #expect(await source.firstStop() == 0)
    }

    @Test("A full buffer fails rather than silently losing ordered bytes")
    func overflow() async throws {
        let source = ServerEventReceiveFixture(chunks: [Data([1]), Data([2])], fails: false)
        let bytes = BridgeServerEventByteStream(bufferLimit: 1).bytes(from: source)
        #expect(await source.firstStop() == 1)
        do {
            for try await _ in bytes {}
            Issue.record("Expected backpressure failure")
        } catch let error as CmxIrohClientServerEventReceiverError {
            #expect(error == .backpressureExceeded)
        }
    }
}

private actor ServerEventReceiveFixture: CmxIrohReceiveStream {
    struct Failure: Error {}
    var chunks: [Data]
    let fails: Bool
    let stopEvents = AsyncStream<UInt64>.makeStream()

    init(chunks: [Data], fails: Bool) {
        self.chunks = chunks
        self.fails = fails
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if fails { throw Failure() }
        return nil
    }

    func stop(errorCode: UInt64) async {
        stopEvents.continuation.yield(errorCode)
    }

    func firstStop() async -> UInt64? {
        var iterator = stopEvents.stream.makeAsyncIterator()
        return await iterator.next()
    }
}
