import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct ClaudeHookSessionStoreRuntimeOrderingTests {
    @Test("An untimestamped idle record cannot demote a live sibling")
    func untimestampedIdleTreatsRunningSiblingAsNewer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-runtime-ordering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        try writeState(
            to: stateURL,
            excludedEventTime: nil,
            siblingEventTime: nil
        )
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path
        ])

        #expect(try store.hasRunningSession(
            workspaceId: "workspace",
            surfaceId: "surface",
            excludingSessionId: "completed",
            onlyNewerThanExcludedSession: true,
            requireLiveProcess: true,
            requireActiveTurn: true
        ))
    }

    @Test("Timestamped ordering still rejects an older running sibling")
    func timestampedIdleRequiresStrictlyNewerSibling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-runtime-ordering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        try writeState(to: stateURL, excludedEventTime: 200, siblingEventTime: 100)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path
        ])

        #expect(!(try store.hasRunningSession(
            workspaceId: "workspace",
            surfaceId: "surface",
            excludingSessionId: "completed",
            onlyNewerThanExcludedSession: true,
            requireLiveProcess: true,
            requireActiveTurn: true
        )))
    }

    private func writeState(
        to url: URL,
        excludedEventTime: TimeInterval?,
        siblingEventTime: TimeInterval?
    ) throws {
        let completed: [String: Any] = [
            "sessionId": "completed",
            "workspaceId": "workspace",
            "surfaceId": "surface",
            "startedAt": 1,
            "updatedAt": 1,
            "runtimeStatus": "idle",
        ]
        var running: [String: Any] = [
            "sessionId": "replacement",
            "workspaceId": "workspace",
            "surfaceId": "surface",
            "startedAt": 1,
            "updatedAt": 1,
            "runtimeStatus": "running",
            "activePromptDepth": 1,
            "pid": Int(getpid()),
        ]
        if let siblingEventTime {
            running["runtimeStatusEventTime"] = siblingEventTime
        }
        var sessions: [String: Any] = [
            "completed": completed,
            "replacement": running,
        ]
        if let excludedEventTime {
            var timestampedCompleted = completed
            timestampedCompleted["runtimeStatusEventTime"] = excludedEventTime
            sessions["completed"] = timestampedCompleted
        }
        let object: [String: Any] = [
            "version": 1,
            "sessions": sessions,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
