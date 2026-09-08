import Darwin
import Dispatch
import Foundation

extension ClaudeHookLiveDeliveryHarness {
    static func mutateTaskSyncSidecar(
        for storeURL: URL,
        _ mutation: (inout [String: Any]) -> Void
    ) throws {
        let sidecarURL = URL(fileURLWithPath: storeURL.path + ".task-sync.json")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
        var state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: sidecarURL)
        ) as? [String: Any] ?? [:]
        mutation(&state)
        let data = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sidecarURL)
    }

    static func taskSyncReconcileRequests(in context: Context) -> [[String: Any]] {
        context.state.snapshot().compactMap { command -> [String: Any]? in
            guard let request = jsonObject(command),
                  request["method"] as? String == "workspace.todo.reconcile" else {
                return nil
            }
            guard let params = request["params"] as? [String: Any],
                  params["validate_only"] as? Bool != true else {
                return nil
            }
            return params
        }.flatMap { params -> [[String: Any]] in
            guard let workspaceIDs = params["workspace_ids"] as? [String] else {
                return [params]
            }
            return workspaceIDs.map { workspaceID in
                var expanded = params
                expanded.removeValue(forKey: "workspace_ids")
                expanded["workspace_id"] = workspaceID
                return expanded
            }
        }
    }

    static func taskSyncReconcileValidationRequests(in context: Context) -> [[String: Any]] {
        context.state.snapshot().compactMap { command -> [String: Any]? in
            guard let request = jsonObject(command),
                  request["method"] as? String == "workspace.todo.reconcile",
                  let params = request["params"] as? [String: Any],
                  params["validate_only"] as? Bool == true else {
                return nil
            }
            return params
        }.flatMap { params -> [[String: Any]] in
            if let workspaceIDs = params["workspace_ids"] as? [String] {
                return workspaceIDs.map { workspaceID in
                    var copy = params
                    copy["workspace_id"] = workspaceID
                    return copy
                }
            }
            return [params]
        }
    }

    static func resumeBindingParams(in context: Context) -> [[String: Any]] {
        context.state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
    }

    static func writeSessionStore(
        to storeURL: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        pid: Int? = nil,
        claudeTaskDirectoryName: String? = nil,
        claudeTaskStoreID: String? = nil,
        markActive: Bool = false
    ) throws {
        let now = Date().timeIntervalSince1970
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": cwd,
            "isRestorable": true,
            "startedAt": now,
            "updatedAt": now,
        ]
        if let pid { record["pid"] = pid }
        if let claudeTaskDirectoryName {
            record["claudeTaskDirectoryName"] = claudeTaskDirectoryName
        }
        if let claudeTaskStoreID {
            record["claudeTaskStoreID"] = claudeTaskStoreID
        }
        var store: [String: Any] = [
            "version": 1,
            "sessions": [sessionId: record],
        ]
        if markActive {
            let active: [String: Any] = [
                "sessionId": sessionId,
                "updatedAt": now,
            ]
            store["activeSessionsByWorkspace"] = [workspaceId: active]
            store["activeSessionsBySurface"] = [surfaceId: active]
        }
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: storeURL)
    }

    static func sessionRecord(in storeURL: URL, sessionId: String) throws -> [String: Any]? {
        // A hook that fails closed before its first accepted upsert never
        // creates the store file; that is the strongest form of "no record".
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        let sessions = saved?["sessions"] as? [String: Any]
        return sessions?[sessionId] as? [String: Any]
    }

    static func runHookProcess(
        context: Context,
        arguments: [String],
        environment: [String: String],
        standardInput: String
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: context.cliPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
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
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }

    static func startMockServer(
        listenerFD: Int32,
        state: ServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        state.markServerStarted()
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { state.signalServerStopped() }
            while true {
                if state.serverIsStopped() { return }
                var readiness = pollfd(
                    fd: listenerFD,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let pollResult = Darwin.poll(&readiness, 1, 100)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if pollResult == 0 { continue }
                if state.serverIsStopped() { return }
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    if errno == EINTR { continue }
                    if state.serverIsStopped() { return }
                    return
                }

                if state.serverIsStopped() {
                    Darwin.close(clientFD)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        Darwin.close(clientFD)
                        handled.signal()
                    }

                    func writeResponse(_ response: String) {
                        let line = response + "\n"
                        _ = line.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }

                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
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
                            state.append(line)
                            writeResponse(handler(line))
                        }
                    }
                }
            }
        }
        return handled
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

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }
}
