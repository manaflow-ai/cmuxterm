import IrohLib

extension IrohSubstrate {
    /// Converts the native handshake result into the peer that owns its streams.
    func startPeer(
        role: IrohPeerConnection.Role,
        connect: @Sendable () async throws -> Connection
    ) async throws -> IrohPeerConnection {
        let connection = try await connect()
        if case .dialer = role { try Task.checkCancellation() }
        let peer = IrohPeerConnection(connection: connection, role: role)
        await peer.start()
        return peer
    }
}
