import Foundation
import IrohLib

/// One lane on one QUIC stream. Single-consumer, like every lane (see
/// LaneFrames); the channel actor serializes writers so concurrent sends
/// cannot interleave bytes mid-frame.
public actor IrohLane: TransportLane {
    public nonisolated let name: String
    let channel: IrohLaneChannel
    /// Stable token used by the owning connection to remove this lane only
    /// if the callback belongs to the currently registered stream.
    nonisolated let token: UUID
    private let onEnd: (@Sendable () async -> Void)?
    private var endNotified = false

    init(
        name: String,
        channel: IrohLaneChannel,
        token: UUID = UUID(),
        onEnd: (@Sendable () async -> Void)? = nil
    ) {
        self.name = name
        self.channel = channel
        self.token = token
        self.onEnd = onEnd
    }

    public func send(_ frame: Frame) async throws {
        try await channel.sendFrame(frame)
    }

    public func receive() async -> Frame? {
        let frame = await channel.receiveFrame()
        if frame == nil, !endNotified {
            endNotified = true
            await onEnd?()
        }
        return frame
    }

    /// Number of short writes observed while QUIC flow control applied
    /// backpressure to this lane.
    public var backpressureStalls: Int {
        get async { await channel.backpressureStalls }
    }

    func finishSend() async {
        await channel.finish()
    }
}
