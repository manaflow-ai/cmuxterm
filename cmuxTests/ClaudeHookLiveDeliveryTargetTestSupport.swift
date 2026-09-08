import Darwin
import Dispatch
import Foundation

/// Shared harness for the issue-7939 live delivery-target CLI regression
/// tests: a mock cmux control server that can answer (or refuse) the
/// `agent.resolve_delivery_target` probes, plus process/session-store
/// helpers. Kept out of the test suite file for the 500-line file budget.
enum ClaudeHookLiveDeliveryHarness {
    struct Context {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: ServerState
        let root: URL
        let storeURL: URL

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }



    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    struct TaskSyncDeliverySignals {
        let feed = DispatchSemaphore(value: 0)
        let reconciliation = DispatchSemaphore(value: 0)
        let validation = DispatchSemaphore(value: 0)
    }

    static func makeContext(name: String) throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
        return Context(
            cliPath: try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: ServerState(),
            root: root,
            storeURL: root.appendingPathComponent("claude-hook-sessions.json")
        )
    }

    static func hookEnvironment(context: Context) -> [String: String] {
        [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.storeURL.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
    }

    /// Mock control server. `pidTarget` answers the `{pid}` probe;
    /// `surfaceTargets` answers `{surface_id}` re-home probes;
    /// `resolverMethodAvailable: false` simulates an older app.
    static func startDeliveryTargetServer(
        context: Context,
        surfacesByWorkspace: [String: [String]],
        pidTarget: (workspaceId: String, surfaceId: String)?,
        surfaceTargets: [String: String] = [:],
        ttyRows: [(tty: String, workspaceId: String, surfaceId: String)] = [],
        resolverMethodAvailable: Bool = true,
        acknowledgesPIDResolution: Bool = true,
        resumeClearSucceeds: Bool = true,
        resumeClearOwnsCheckpoint: Bool? = true
    ) -> DispatchSemaphore {
        startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "agent.resolve_delivery_target":
                guard resolverMethodAvailable else {
                    return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unknown method"])
                }
                if params["pid"] != nil {
                    guard let pidTarget else {
                        return v2Response(id: id, ok: false, error: ["code": "not_found", "message": "pid not owned by a live surface"])
                    }
                    var result: [String: Any] = [
                        "workspace_id": pidTarget.workspaceId,
                        "surface_id": pidTarget.surfaceId,
                        "source": "pid",
                    ]
                    if acknowledgesPIDResolution {
                        result["pid_resolution"] = params["pid_resolution"] as? String ?? "corroborated"
                    }
                    return v2Response(id: id, ok: true, result: result)
                }
                if let surfaceId = params["surface_id"] as? String,
                   let workspaceId = surfaceTargets[surfaceId] {
                    return v2Response(id: id, ok: true, result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "source": "surface",
                    ])
                }
                return v2Response(id: id, ok: false, error: ["code": "not_found", "message": "no live target"])
            case "surface.list":
                guard let workspaceId = params["workspace_id"] as? String,
                      let surfaceIds = surfacesByWorkspace[workspaceId] else {
                    return v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
                }
                let surfaces: [[String: Any]] = surfaceIds.enumerated().map { index, surfaceId in
                    ["id": surfaceId, "ref": "surface:\(index + 1)", "focused": index == 0]
                }
                return v2Response(id: id, ok: true, result: ["surfaces": surfaces])
            case "debug.terminals":
                let terminals: [[String: Any]] = ttyRows.map {
                    ["tty": $0.tty, "workspace_id": $0.workspaceId, "surface_id": $0.surfaceId]
                }
                return v2Response(id: id, ok: true, result: ["terminals": terminals])
            case "feed.push":
                return v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            case "surface.resume.clear":
                if resumeClearSucceeds {
                    guard let resumeClearOwnsCheckpoint else {
                        return v2Response(id: id, ok: true, result: [:])
                    }
                    return v2Response(
                        id: id,
                        ok: true,
                        result: ["cleared": resumeClearOwnsCheckpoint]
                    )
                }
                return v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "cleanup_failed", "message": "injected resume cleanup failure"]
                )
            default:
                return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }
    }

    /// Mock server for the task-sync hook's routing, Feed, and checklist calls.
    static func startTaskSyncServer(
        context: Context,
        workspaceId: String,
        surfaceId: String,
        workspaceIDsBySurface: [String: String] = [:],
        missingWorkspaceIDs: Set<String> = [],
        feedPushSucceeds: Bool = true,
        rejectsEmptyFeedSnapshots: Bool = false
    ) -> TaskSyncDeliverySignals {
        let deliveries = TaskSyncDeliverySignals()
        _ = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = jsonObject(line),
                  let method = payload["method"] as? String else {
                return "OK"
            }
            if method == "feed.push" {
                deliveries.feed.signal()
                let params = payload["params"] as? [String: Any]
                let event = params?["event"] as? [String: Any]
                let toolInput = event?["tool_input"] as? [String: Any]
                let todos = toolInput?["todos"] as? [[String: Any]]
                let rejectsSnapshot = rejectsEmptyFeedSnapshots && todos?.isEmpty == true
                guard feedPushSucceeds, !rejectsSnapshot else {
                    guard let id = payload["id"] as? String else {
                        return "ERROR: injected Feed rejection"
                    }
                    return v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "delivery_failed", "message": "injected Feed rejection"]
                    )
                }
                if let id = payload["id"] as? String {
                    return v2Response(id: id, ok: true, result: [:])
                }
                return "OK"
            }
            guard let id = payload["id"] as? String else {
                return "OK"
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "agent.resolve_delivery_target":
                let requestedSurfaceID = params["surface_id"] as? String
                let resolvedWorkspaceID = requestedSurfaceID.flatMap {
                    workspaceIDsBySurface[$0]
                } ?? workspaceId
                return v2Response(id: id, ok: true, result: [
                    "workspace_id": resolvedWorkspaceID,
                    "surface_id": requestedSurfaceID ?? surfaceId,
                    "source": "surface",
                ])
            case "surface.list":
                let requestedWorkspaceID = params["workspace_id"] as? String
                let resolvedSurfaceID = workspaceIDsBySurface.first {
                    $0.value == requestedWorkspaceID
                }?.key ?? surfaceId
                return v2Response(id: id, ok: true, result: [
                    "surfaces": [["id": resolvedSurfaceID, "ref": "surface:1", "focused": true]],
                ])
            case "workspace.todo.reconcile":
                let items = params["items"] as? [[String: Any]] ?? []
                let validateOnly = params["validate_only"] as? Bool == true
                if items.count > 50 {
                    let destinationCount = (params["workspace_ids"] as? [String])?.count ?? 1
                    for _ in 0..<destinationCount {
                        if validateOnly {
                            deliveries.validation.signal()
                        } else {
                            deliveries.reconciliation.signal()
                        }
                    }
                    return v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "invalid_params", "message": "checklist cap exceeded"]
                    )
                }
                if let destinationWorkspaceIDs = params["workspace_ids"] as? [String] {
                    let results: [[String: Any]] = destinationWorkspaceIDs.map { workspaceID in
                        if validateOnly {
                            deliveries.validation.signal()
                        } else {
                            deliveries.reconciliation.signal()
                        }
                        if missingWorkspaceIDs.contains(workspaceID) {
                            if validateOnly {
                                return ["workspace_id": workspaceID, "ok": true]
                            }
                            return [
                                "workspace_id": workspaceID,
                                "ok": false,
                                "error": ["code": "not_found", "message": "workspace closed"],
                            ]
                        }
                        return ["workspace_id": workspaceID, "ok": true]
                    }
                    return v2Response(id: id, ok: true, result: ["results": results])
                }
                if validateOnly {
                    deliveries.validation.signal()
                } else {
                    deliveries.reconciliation.signal()
                }
                if let destinationWorkspaceID = params["workspace_id"] as? String,
                   missingWorkspaceIDs.contains(destinationWorkspaceID) {
                    if validateOnly {
                        return v2Response(id: id, ok: true, result: [:])
                    }
                    return v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "workspace closed"]
                    )
                }
                return v2Response(id: id, ok: true, result: [:])
            default:
                return v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }
        return deliveries
    }

}
