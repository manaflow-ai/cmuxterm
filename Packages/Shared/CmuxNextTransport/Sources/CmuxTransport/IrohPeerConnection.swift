import Foundation
import IrohLib

/// One live iroh QUIC connection behind the substrate seam.
///
/// Lane protocol: the DIALER opens lanes; each new bidirectional stream's
/// first frame is `lane.open {name}`. The ACCEPTOR's `lane(_:)` waits until
/// the peer opens that name. This mirrors how the host code already consumes
/// lanes (it awaits "ctl" first, then named lanes on demand).
public actor IrohPeerConnection: PeerConnection {
    public enum Role: Sendable {
        case dialer, acceptor
    }

    static let laneOpenType = "lane.open"
    static let rawOpenType = "raw.open"

    let connection: Connection
    let role: Role
    let remoteKey: Data
    /// Genuine handshake deadline; injected for deterministic tests and to
    /// ensure a peer cannot park the accept loop forever before sending the
    /// first lane frame.
    let handshakeSleep: @Sendable (Duration) async throws -> Void
    var lanes: [String: IrohLane] = [:]
    var laneWaiters: [String: [(id: UInt64, continuation: CheckedContinuation<any TransportLane, Never>)]] = [:]
    var laneWaiterTasks: [UInt64: Task<Void, Never>] = [:]
    private var laneWaiterCounter: UInt64 = 0
    private var acceptLoop: Task<Void, Never>?
    /// One bounded worker per accepted bidirectional stream. The accept loop
    /// itself never waits for a peer's `lane.open`/`raw.open` handshake.
    var inboundStreamTasks: [UInt64: Task<Void, Never>] = [:]
    var inboundStreamCounter: UInt64 = 0
    var rawStreamHandler: (@Sendable (String, RawByteStream) async -> Void)?
    var pendingRawStreams: [(String, RawByteStream)] = []
    /// A single FIFO delivery task preserves the arrival order promised by
    /// `onRawStream`; one task per stream could be scheduled out of order.
    var rawDeliveryQueue: [(String, RawByteStream)] = []
    var rawDeliveryHead = 0
    var rawDeliveryTask: Task<Void, Never>?
    var closedFlag = false
    var localTermination: ConnectionTermination?

    static let maxConcurrentInboundStreams = 64
    static let maxLaneCount = 128
    static let inboundOpenDeadline: Duration = .seconds(10)
    private static let laneWaitDeadline: Duration = .seconds(10)

    public init(
        connection: Connection,
        role: Role,
        handshakeSleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.connection = connection
        self.role = role
        self.remoteKey = connection.remoteId().toBytes()
        self.handshakeSleep = handshakeSleep
    }

    /// Must be called once after init (an actor cannot spawn tasks on itself
    /// mid-init); the factory methods on IrohSubstrate do this. Both roles
    /// run the inbound accept loop: the acceptor for peer-opened lanes, the
    /// dialer for host-opened streams (server events over the graduation
    /// bridge). A dialer that never receives one just parks on acceptBi.
    public func start() {
        guard acceptLoop == nil else { return }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) start \
                role=\(String(describing: self.role), privacy: .public) \
                remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public)
                """)
        }
        acceptLoop = Task { await self.runAcceptLoop() }
    }

    /// iroh always authenticates the remote endpoint key during the QUIC
    /// handshake; admission judges grants against THIS (contract 3.5).
    public var authenticatedRemoteKey: Data? { remoteKey }

    public var isClosed: Bool {
        closedFlag || connection.closeReason() != nil
    }

    /// Graduation bridge: registers the single owner of inbound raw
    /// application streams. Streams that arrived before registration are
    /// delivered immediately, in arrival order.
    public func onRawStream(
        _ handler: @escaping @Sendable (String, RawByteStream) async -> Void
    ) async {
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) raw-stream handler \
                registered pendingFlushed=\(self.pendingRawStreams.count, privacy: .public)
                """)
        }
        rawStreamHandler = handler
        rawDeliveryQueue.append(contentsOf: pendingRawStreams)
        pendingRawStreams.removeAll()
        startRawDeliveryIfNeeded()
    }

    /// Graduation bridge: opens one raw application stream. One handshake
    /// frame carries the preamble; every byte after it is unframed and owned
    /// by the caller (identical wire shape to the legacy transport's lanes).
    public func openRawStream(preamble: String) async throws -> RawByteStream {
        guard !closedFlag else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) openRawStream REFUSED \
                    (connection closed) preamble=\(preamble, privacy: .public)
                    """)
            }
            throw TransportError.pipeClosed
        }
        do {
            let stream = try await connection.openBi()
            let channel = IrohLaneChannel(send: stream.send(), recv: stream.recv())
            try await channel.sendFrame(
                Frame(type: Self.rawOpenType, payload: ["preamble": .string(preamble)]))
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) raw stream opened \
                    preamble=\(preamble, privacy: .public)
                    """)
            }
            return RawByteStream(send: stream.send(), recv: stream.recv(), buffered: Data())
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) openRawStream FAILED \
                    preamble=\(preamble, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """)
            }
            throw error
        }
    }

    public func lane(_ name: String) async -> any TransportLane {
        if let existing = lanes[name] { return existing }
        if closedFlag {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) lane \
                    name=\(name, privacy: .public) -> dead lane (connection closed)
                    """)
            }
            return DeadLane(name: name)
        }
        switch role {
        case .dialer:
            guard lanes.count < Self.maxLaneCount else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        "conn \(TransportDebugLog.id(self), privacy: .public) lane limit reached (\(Self.maxLaneCount, privacy: .public)); refusing name=\(name, privacy: .public)")
                }
                return DeadLane(name: name)
            }
            do {
                let stream = try await connection.openBi()
                // Re-check after the suspension: a concurrent caller may have
                // opened the same lane while we awaited. The loser must CLOSE
                // the stream it already opened — dropping the handle leaks a
                // live QUIC stream (and its flow-control credit) for the
                // connection's whole lifetime.
                if let existing = lanes[name] {
                    try? await stream.send().finish()
                    try? await stream.recv().stop(errorCode: 0)
                    return existing
                }
                let channel = IrohLaneChannel(
                    send: stream.send(), recv: stream.recv(),
                    onProtocolError: { [weak self] in
                        await self?.protocolViolation()
                    })
                try await channel.sendFrame(
                    Frame(type: Self.laneOpenType, payload: ["name": .string(name)]))
                let lane = makeLane(name: name, channel: channel)
                lanes[name] = lane
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) lane opened \
                        (dialer) name=\(name, privacy: .public)
                        """)
                }
                return lane
            } catch {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) lane open FAILED \
                        (dialer) name=\(name, privacy: .public) \
                        error=\(String(describing: error), privacy: .public) -> dead lane
                        """)
                }
                return DeadLane(name: name)
            }
        case .acceptor:
            laneWaiterCounter &+= 1
            let waiterID = laneWaiterCounter
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if let existing = lanes[name] {
                        continuation.resume(returning: existing)
                    } else if closedFlag {
                        if TransportDebugLog.enabled {
                            TransportDebugLog.core.notice(
                                """
                                conn \(TransportDebugLog.id(self), privacy: .public) lane \
                                name=\(name, privacy: .public) -> dead lane (closed while waiting)
                                """)
                        }
                        continuation.resume(returning: DeadLane(name: name))
                    } else {
                        if TransportDebugLog.enabled {
                            TransportDebugLog.core.notice(
                                """
                                conn \(TransportDebugLog.id(self), privacy: .public) lane wait \
                                (acceptor) name=\(name, privacy: .public) \
                                waiters=\((self.laneWaiters[name]?.count ?? 0) + 1, privacy: .public)
                                """)
                        }
                        laneWaiters[name, default: []].append(
                            (id: waiterID, continuation: continuation))
                        let sleep = handshakeSleep
                        laneWaiterTasks[waiterID] = Task { [weak self] in
                            do {
                                try await sleep(Self.laneWaitDeadline)
                            } catch {
                                return
                            }
                            guard let self else { return }
                            await self.expireLaneWaiter(name: name, id: waiterID)
                        }
                    }
                }
            }, onCancel: {
                Task { [weak self] in
                    await self?.cancelLaneWaiter(name: name, id: waiterID)
                }
            })
        }
    }

    /// Resolves one acceptor waiter as a dead lane after the bounded deadline.
    private func expireLaneWaiter(name: String, id: UInt64) {
        guard var waiters = laneWaiters[name],
            let index = waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            laneWaiters.removeValue(forKey: name)
        } else {
            laneWaiters[name] = waiters
        }
        laneWaiterTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: DeadLane(name: name))
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                "conn \(TransportDebugLog.id(self), privacy: .public) lane wait expired name=\(name, privacy: .public)")
        }
    }

    /// Removes a cancelled waiter without resuming it twice.
    private func cancelLaneWaiter(name: String, id: UInt64) {
        guard var waiters = laneWaiters[name],
            let index = waiters.firstIndex(where: { $0.id == id })
        else {
            laneWaiterTasks.removeValue(forKey: id)?.cancel()
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            laneWaiters.removeValue(forKey: name)
        } else {
            laneWaiters[name] = waiters
        }
        laneWaiterTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: DeadLane(name: name))
    }

    /// No sleeps, no drains (Aziz redline 08-19: we can't depend on time).
    /// The reason rides in the QUIC CONNECTION_CLOSE itself, which the
    /// protocol delivers and retransmits during shutdown; stream frames that
    /// lose the race are irrelevant because termination() carries the cause.
    public func closeAll(reason: ConnectionTermination?) async {
        guard !closedFlag else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) closeAll ignored \
                    (already closed) reason=\(reason?.code ?? "nil", privacy: .public)
                    """)
            }
            return
        }
        closedFlag = true
        localTermination = reason
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) closeAll initiator=local \
                reason=\(reason?.code ?? "nil", privacy: .public) \
                role=\(String(describing: self.role), privacy: .public) \
                remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public) \
                openLanes=\(self.lanes.count, privacy: .public) \
                laneWaiters=\(self.laneWaiters.values.reduce(0) { $0 + $1.count }, privacy: .public)
                """)
        }
        acceptLoop?.cancel()
        for task in inboundStreamTasks.values { task.cancel() }
        inboundStreamTasks.removeAll()
        rawDeliveryTask?.cancel()
        rawDeliveryTask = nil
        rawDeliveryQueue.removeAll()
        rawDeliveryHead = 0
        pendingRawStreams.removeAll()
        for task in laneWaiterTasks.values { task.cancel() }
        laneWaiterTasks.removeAll()
        let openLanes = Array(lanes.values)
        lanes.removeAll()
        for lane in openLanes {
            await lane.finishSend()
        }
        try? connection.close(
            errorCode: reason == nil ? 0 : 1,
            reason: Data((reason?.code ?? "closed").utf8))
        resumeAllWaitersClosed()
    }

    /// Creates a lane whose end callback returns ownership to this
    /// connection, allowing completed streams to leave the bounded registry.
    func makeLane(name: String, channel: IrohLaneChannel) -> IrohLane {
        let token = UUID()
        return IrohLane(name: name, channel: channel, token: token) { [weak self] in
            await self?.laneEnded(name: name, token: token)
        }
    }

    /// Removes a completed lane only when the callback belongs to the stream
    /// currently registered under that name; a newer stream with the same name
    /// must not be removed by a stale EOF callback.
    private func laneEnded(name: String, token: UUID) {
        guard lanes[name]?.token == token else { return }
        lanes.removeValue(forKey: name)
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                "conn \(TransportDebugLog.id(self), privacy: .public) lane released name=\(name, privacy: .public) remaining=\(self.lanes.count, privacy: .public)")
        }
    }

    func resumeAllWaitersClosed() {
        if TransportDebugLog.enabled, !laneWaiters.isEmpty {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) resuming lane waiters as \
                dead lanes lanes=\(self.laneWaiters.keys.joined(separator: ","), privacy: .public) \
                count=\(self.laneWaiters.values.reduce(0) { $0 + $1.count }, privacy: .public)
                """)
        }
        for (name, waiters) in laneWaiters {
            for waiter in waiters {
                laneWaiterTasks.removeValue(forKey: waiter.id)?.cancel()
                waiter.continuation.resume(returning: DeadLane(name: name))
            }
        }
        laneWaiters.removeAll()
        laneWaiterTasks.removeAll()
    }

}
