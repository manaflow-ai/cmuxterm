import Darwin
import Foundation
import Testing

extension CLIHookNoResponseTests {
    static func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: BundleProbe.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Bundled cmux CLI not found in \(appBundleURL.path)",
        ])
    }

    static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    static func bindUnixSocket(at path: String, backlog: Int32) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("failed to create Unix socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "socket path too long: \(path)",
            ])
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw posixError("failed to bind Unix socket")
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            throw posixError("failed to listen on Unix socket")
        }
        return fd
    }

    static func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var didFulfill = false
            func fulfillOnce() {
                if !didFulfill {
                    didFulfill = true
                    handled.signal()
                }
            }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                fulfillOnce()
                return
            }
            defer { Darwin.close(clientFD) }

            readLines(from: clientFD) { line in
                state.append(line)
                if fulfillWhen?(line) == true {
                    fulfillOnce()
                }
                guard let responsePayload = handler(line) else { return }
                writeLine(responsePayload, to: clientFD)
            }
        }
        return MockSocketServer(handled: handled)
    }

    static func startMultiConnectionMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionLimit: Int,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fulfillmentLock = NSLock()
            var didFulfill = false
            func fulfillOnce() {
                fulfillmentLock.lock()
                let shouldFulfill = !didFulfill
                if shouldFulfill {
                    didFulfill = true
                }
                fulfillmentLock.unlock()
                if shouldFulfill {
                    handled.signal()
                }
            }

            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    fulfillOnce()
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    readLines(from: clientFD) { line in
                        state.append(line)
                        if fulfillWhen?(line) == true {
                            fulfillOnce()
                        }
                        guard let responsePayload = handler(line) else { return }
                        writeLine(responsePayload, to: clientFD)
                    }
                }
            }
        }
        return MockSocketServer(handled: handled)
    }

    static func startAcceptedSocketThatDoesNotRead(
        listenerFD: Int32,
        holdFor: TimeInterval
    ) throws -> MockSocketServer {
        var receiveBufferBytes: Int32 = 4 * 1024
        guard setsockopt(
            listenerFD,
            SOL_SOCKET,
            SO_RCVBUF,
            &receiveBufferBytes,
            socklen_t(MemoryLayout.size(ofValue: receiveBufferBytes))
        ) == 0 else {
            throw posixError("failed to constrain non-reading socket receive buffer")
        }

        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.signal()
                return
            }
            handled.signal()
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + holdFor)
            Darwin.close(clientFD)
        }
        return MockSocketServer(handled: handled)
    }

    static func readLines(from fd: Int32, handle: (String) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)

            while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                pending.removeSubrange(0...newlineRange.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                handle(line)
            }
        }
    }

    static func writeLine(_ line: String, to fd: Int32) {
        let response = line + "\n"
        _ = response.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    static func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    static func surfaceListResponse(id: String, surfaceId: String) -> String {
        v2Response(
            id: id,
            ok: true,
            result: ["surfaces": [["id": surfaceId, "ref": "surface:1", "focused": true]]]
        )
    }

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    static func base64NULSeparated(_ values: [String]) -> String {
        values.joined(separator: "\0").data(using: .utf8)?.base64EncodedString() ?? ""
    }

    static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdinHandle: FileHandle?
        let stdinURL: URL?
        if let standardInput {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-test-stdin-\(UUID().uuidString).json")
            do {
                try Data(standardInput.utf8).write(to: url)
                let handle = try FileHandle(forReadingFrom: url)
                process.standardInput = handle
                stdinHandle = handle
                stdinURL = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
            }
        } else {
            stdinHandle = nil
            stdinURL = nil
        }
        defer {
            try? stdinHandle?.close()
            if let stdinURL {
                try? FileManager.default.removeItem(at: stdinURL)
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }

        let timedOut = finished.wait(timeout: .now() + timeout) != .success
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    static func posixError(_ message: String) -> NSError {
        NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(message): errno \(errno)",
        ])
    }
}
