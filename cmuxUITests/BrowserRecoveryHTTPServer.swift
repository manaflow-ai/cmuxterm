import Darwin
import Foundation
import Network

/// A tiny loopback HTTP origin used by browser navigation regressions.
///
/// The UI-test runner is sandboxed. Keeping the listener in this process avoids
/// relying on an unsigned child interpreter inheriting the runner's network
/// entitlements and sandbox extensions.
final class BrowserRecoveryHTTPServer {
    let port: UInt16

    private enum ServerError: Error {
        case couldNotReservePort
        case listenerDidNotBecomeReady
        case listenerPortUnavailable
        case requestTimedOut
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.browser.recovery-http-server")
    private let stateLock = NSLock()
    private let requestSignal = DispatchSemaphore(value: 0)
    private var heldConnection: NWConnection?
    private var expectedPath: String?
    private var isStarted = false

    init() throws {
        let port = try Self.availablePort()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: parameters)
        self.port = port
    }

    deinit {
        stop()
    }

    func start() throws {
        stateLock.lock()
        guard !isStarted else {
            stateLock.unlock()
            return
        }
        isStarted = true
        stateLock.unlock()

        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listenerReady.signal()
            case .failed, .cancelled:
                listenerReady.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard listenerReady.wait(timeout: .now() + 5) == .success,
              listener.state == .ready else {
            listener.cancel()
            throw ServerError.listenerDidNotBecomeReady
        }
        guard listener.port?.rawValue == port else {
            listener.cancel()
            throw ServerError.listenerPortUnavailable
        }
    }

    func waitForRequest() throws {
        guard requestSignal.wait(timeout: .now() + 15) == .success else {
            throw ServerError.requestTimedOut
        }
        stateLock.lock()
        let hasHeldConnection = heldConnection != nil
        stateLock.unlock()
        guard hasHeldConnection else {
            throw ServerError.requestTimedOut
        }
    }

    /// Arms the next matching HTTP path to be held until `releaseResponse()`.
    /// Browser engines may issue favicon or other follow-up requests around a
    /// document navigation; those requests are answered immediately instead of
    /// consuming the synchronization signal for the navigation under test.
    func expectRequest(path: String) {
        stateLock.lock()
        expectedPath = path
        stateLock.unlock()
    }

    func releaseResponse() throws {
        stateLock.lock()
        let connection = heldConnection
        heldConnection = nil
        stateLock.unlock()
        if let connection {
            sendResponse(on: connection)
        }
    }

    func stop() {
        listener.cancel()
        stateLock.lock()
        let connection = heldConnection
        heldConnection = nil
        stateLock.unlock()
        connection?.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard nextBuffer.range(of: Data([13, 10, 13, 10])) != nil else {
                self.receiveRequest(on: connection, buffer: nextBuffer)
                return
            }

            let requestPath = Self.requestPath(from: nextBuffer)
            self.stateLock.lock()
            let shouldHold = self.heldConnection == nil
                && self.expectedPath == requestPath
            if shouldHold {
                self.expectedPath = nil
                self.heldConnection = connection
            }
            self.stateLock.unlock()
            if shouldHold {
                self.requestSignal.signal()
            } else {
                self.sendResponse(on: connection)
            }
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let body = Data("<!doctype html><body data-cmux-recovered=\"true\">recovered</body>".utf8)
        let header = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        connection.send(
            content: header + body,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private static func requestPath(from data: Data) -> String? {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.split(separator: "\r\n", maxSplits: 1).first
        else { return nil }
        return requestLine.split(separator: " ", omittingEmptySubsequences: true)
            .dropFirst()
            .first
            .map(String.init)
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.couldNotReservePort }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { throw ServerError.couldNotReservePort }

        var resolvedAddress = sockaddr_in()
        var resolvedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didResolve = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &resolvedLength)
            }
        }
        guard didResolve == 0 else { throw ServerError.couldNotReservePort }
        return UInt16(bigEndian: resolvedAddress.sin_port)
    }
}
