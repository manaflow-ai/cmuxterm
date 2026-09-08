import CmuxIrohTransport
import Foundation

/// Converts one adopted server-event receive half into ordered, bounded bytes.
public struct BridgeServerEventByteStream: Sendable {
    private let bufferLimit: Int

    /// Creates the adapter with a bounded oldest-first chunk buffer.
    /// - Parameter bufferLimit: The maximum number of unread chunks.
    public init(bufferLimit: Int = 32) {
        self.bufferLimit = max(1, bufferLimit)
    }

    /// Starts the receive pump outside the UI actor.
    /// - Parameter receiveStream: The already-adopted server-event receive half.
    /// - Returns: Ordered payload bytes, failing closed on overflow or read errors.
    public func bytes(from receiveStream: any CmxIrohReceiveStream) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(bufferLimit)) { continuation in
            let pump = Task { await run(receiveStream, continuation: continuation) }
            continuation.onTermination = { _ in
                pump.cancel()
                Task { await receiveStream.stop(errorCode: 0) }
            }
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated func run(
        _ receiveStream: any CmxIrohReceiveStream,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        do {
            while let chunk = try await receiveStream.receive(maximumByteCount: 1 << 16) {
                switch continuation.yield(chunk) {
                case .enqueued: break
                case .terminated: return
                case .dropped:
                    continuation.finish(throwing: CmxIrohClientServerEventReceiverError.backpressureExceeded)
                    await receiveStream.stop(errorCode: 1)
                    return
                @unknown default:
                    continuation.finish(throwing: CmxIrohClientServerEventReceiverError.backpressureExceeded)
                    await receiveStream.stop(errorCode: 1)
                    return
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
