import Foundation
public import IrohLib

/// The iroh-mode substrate (contract 2.1, D7 rung 1): real QUIC connections
/// via stock upstream iroh (cmux-lite IrohLib branch), plugged into the same
/// `PeerConnection` seam the loopback implements. Lanes map one-to-one onto
/// bidirectional QUIC streams, so cross-lane independence (5.2) is physical.
public enum IrohSubstrate {
    public static var alpn: Data { Data(CmuxPeerProtocol.identifier.utf8) }

    /// Build and bind an endpoint whose network identity IS the peer identity
    /// (contract 1.1): the Ed25519 key seeds iroh's secret key, so the remote
    /// side's substrate-authenticated key equals `identity.publicKeyData`.
    /// `minimalLoopback` binds to 127.0.0.1 with no relays and no discovery,
    /// for in-process live-QUIC tests; the relay-fleet configuration is P1e.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func endpoint(
        identity: PeerIdentity, minimalLoopback: Bool
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        if minimalLoopback {
            try builder.bindAddr(addr: "127.0.0.1:0")
        }
        let endpoint = try await builder.bind()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                endpoint bound id=\(TransportDebugLog.hex8(endpoint.id().toBytes()), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                relays=0 loopback=\(minimalLoopback, privacy: .public) \
                sockets=\(endpoint.boundSockets().count, privacy: .public)
                """)
        }
        return endpoint
    }

    /// One authenticated relay (contract 9.1): our fleet requires an
    /// endpoint-bound token on the websocket upgrade. Rotation: `insertRelay`
    /// ALONE with the fresh token — our iroh fork authenticates a replacement
    /// connection before swapping routes, so live sessions continue
    /// (make-before-break). Never removeRelay first: remove cancels the
    /// active relay immediately and severs every session riding it.
    public struct RelayAccess: Sendable {
        public var url: String
        public var quicPort: UInt16?
        public var authToken: String?

        public init(url: String, quicPort: UInt16? = nil, authToken: String? = nil) {
            self.url = url
            self.quicPort = quicPort
            self.authToken = authToken
        }
    }

    /// Relay-enabled endpoint (P1e): identity-seeded like the loopback
    /// variant, but with a custom relay map pointing at our fleet.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func endpoint(
        identity: PeerIdentity, relays: [RelayAccess]
    ) async throws -> Endpoint {
        let builder = EndpointBuilder()
        builder.applyMinimal()
        try builder.secretKey(bytes: identity.privateKeyData)
        builder.alpns(alpns: [alpn])
        let map = RelayMap.empty()
        for relay in relays {
            try map.insert(
                config: RelayConfig(
                    url: relay.url, quicPort: relay.quicPort, authToken: relay.authToken))
        }
        builder.relayMode(mode: RelayMode.custom(map: map))
        let endpoint = try await builder.bind()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                endpoint bound id=\(TransportDebugLog.hex8(endpoint.id().toBytes()), privacy: .public) \
                device=\(TransportDebugLog.prefix(identity.deviceID), privacy: .public) \
                relays=\(relays.count, privacy: .public) \
                relayUrls=\(relays.map(\.url).joined(separator: ","), privacy: .public) \
                sockets=\(endpoint.boundSockets().count, privacy: .public)
                """)
        }
        return endpoint
    }

    /// The endpoint key a fleet token is bound to (its JWT `endpoint_id`
    /// claim), or nil if the token doesn't parse. Deterministic and offline.
    /// The relay refuses a wrong-key token with NO client-visible error (the
    /// route just looks dead), so callers must compare this against their own
    /// `identity.publicKeyData` BEFORE dialing and say so loudly on mismatch.
    public static func tokenEndpointId(_ token: String) -> Data? {
        guard let hex = tokenClaims(token)?["endpoint_id"]?.stringValue,
            hex.count % 2 == 0
        else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// When a fleet token stops being honored (its JWT `exp` claim, epoch
    /// seconds), or nil if it doesn't parse. Tokens live 300s; dialing with
    /// an expired one makes the relay route silently dead, so callers should
    /// name it (the 08-21 "chat died at +5min" field bite).
    public static func tokenExpiry(_ token: String) -> Int64? {
        tokenClaims(token)?["exp"]?.intValue
    }

    private static func tokenClaims(_ token: String) -> [String: JSONValue]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    /// A relay-only address: no direct candidates at all, so the connection
    /// can only be established through the relay (harness spec 2.2).
    public static func relayAddr(id: Data, relayUrl: String) throws -> EndpointAddr {
        EndpointAddr(id: try EndpointId.fromBytes(bytes: id), relayUrl: relayUrl, addresses: [])
    }

    /// The dialable address of a bound endpoint, for tests and LAN dials.
    public static func directAddr(of endpoint: Endpoint) -> EndpointAddr {
        let addresses = endpoint.boundSockets().map {
            $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        return EndpointAddr(id: endpoint.id(), relayUrl: nil, addresses: addresses)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func dial(
        endpoint: Endpoint, to addr: EndpointAddr
    ) async throws -> IrohPeerConnection {
        let dialStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate dial begin target=\(TransportDebugLog.hex8(addr.id().toBytes()), privacy: .public) \
                addrs=\(addr.directAddresses().count, privacy: .public) \
                relay=\(addr.relayUrl() ?? "none", privacy: .public)
                """)
        }
        let connection: Connection
        do {
            // Keep the cancellable ConnectAttempt handle alive for the whole
            // FFI handshake. A timeout or owner shutdown cancels this task;
            // the attempt's Rust cancellation token then releases a UDP
            // blackhole instead of leaving the caller parked in `connect()`.
            let attempt = try endpoint.beginConnect(addr: addr, alpn: alpn)
            connection = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                let connected = try await attempt.connect()
                try Task.checkCancellation()
                return connected
            }, onCancel: {
                attempt.cancel()
            })
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    substrate dial FAILED target=\(TransportDebugLog.hex8(addr.id().toBytes()), privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                    """)
            }
            throw error
        }
        let peer = IrohPeerConnection(connection: connection, role: .dialer)
        await peer.start()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate dial connected conn=\(TransportDebugLog.id(peer), privacy: .public) \
                remote=\(TransportDebugLog.hex8(connection.remoteId().toBytes()), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                """)
        }
        return peer
    }

    /// Pull and complete the next incoming connection. Returns nil once the
    /// endpoint is closed.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func acceptOne(endpoint: Endpoint) async throws -> IrohPeerConnection? {
        guard let incoming = await endpoint.acceptNext() else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice("substrate acceptOne: endpoint closed (nil incoming)")
            }
            return nil
        }
        let acceptStart = ContinuousClock.now
        let connection: Connection
        do {
            let accepting = try await incoming.accept()
            connection = try await accepting.connect()
        } catch {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    substrate acceptOne FAILED error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: acceptStart), privacy: .public)
                    """)
            }
            throw error
        }
        let peer = IrohPeerConnection(connection: connection, role: .acceptor)
        await peer.start()
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                substrate accepted conn=\(TransportDebugLog.id(peer), privacy: .public) \
                remote=\(TransportDebugLog.hex8(connection.remoteId().toBytes()), privacy: .public) \
                elapsedMs=\(TransportDebugLog.ms(since: acceptStart), privacy: .public)
                """)
        }
        return peer
    }
}
