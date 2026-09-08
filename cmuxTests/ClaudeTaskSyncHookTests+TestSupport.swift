import CMUXAgentLaunch
import Dispatch
import Foundation
import Testing

extension ClaudeTaskSyncHookTests {
    func assertSuccessfulHook(
        _ result: ClaudeHookLiveDeliveryHarness.ProcessRunResult
    ) {
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n", Comment(rawValue: result.stderr))
    }

    func fileSystemNumber(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    func runHook(
        context: ClaudeHookLiveDeliveryHarness.Context,
        environment: [String: String],
        sessionId: String,
        toolName: String,
        standardInput: String? = nil
    ) -> ClaudeHookLiveDeliveryHarness.ProcessRunResult {
        ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "task-sync"],
            environment: environment,
            standardInput: standardInput
                ?? #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"\#(toolName)"}"#
        )
    }

    func writeTask(_ json: String, named name: String, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    func setTeamBindingUpdatedAt(
        _ updatedAt: TimeInterval,
        taskListID: String,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var bindings = try #require(
            state["claudeTeamTaskBindings"] as? [String: [String: Any]]
        )
        let bindingEntry = try #require(bindings.first { _, record in
            let binding = record["binding"] as? [String: Any]
            return binding?["taskListID"] as? String == taskListID
        })
        var record = bindingEntry.value
        record["updatedAt"] = updatedAt
        bindings[bindingEntry.key] = record
        state["claudeTeamTaskBindings"] = bindings
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
        try ClaudeHookLiveDeliveryHarness.mutateTaskSyncSidecar(for: storeURL) { sidecar in
            sidecar["claudeTeamTaskBindings"] = state["claudeTeamTaskBindings"]
        }
    }

    func addLegacyTaskSessionRecord(
        to storeURL: URL,
        sourceSessionId: String,
        sessionId: String,
        workspaceId: String,
        surfaceId: String
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var sessions = try #require(state["sessions"] as? [String: [String: Any]])
        var record = try #require(sessions[sourceSessionId])
        record["sessionId"] = sessionId
        record["workspaceId"] = workspaceId
        record["surfaceId"] = surfaceId
        sessions[sessionId] = record
        state["sessions"] = sessions
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
        try ClaudeHookLiveDeliveryHarness.mutateTaskSyncSidecar(for: storeURL) { sidecar in
            sidecar["sessions"] = state["sessions"]
        }
    }

    func taskOwnerID(
        directoryName: String,
        tasksRootURL: URL
    ) -> String {
        let taskStoreIdentity = ClaudeTaskStoreIdentity(
            tasksRootURL: tasksRootURL
        )
        return "claude:\(taskStoreIdentity.rawValue):\(directoryName)"
    }

    func taskListDestinationRecords(
        in storeURL: URL
    ) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: storeURL)
        let state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return state["claudeTaskListDestinations"] as? [String: [String: Any]] ?? [:]
    }

    func retireTaskList(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        retiredAt: TimeInterval,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var retired = state["retiredClaudeTaskLists"] as? [String: TimeInterval] ?? [:]
        retired["\(taskStoreIdentity.rawValue):\(taskListID)"] = retiredAt
        state["retiredClaudeTaskLists"] = retired
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
        try ClaudeHookLiveDeliveryHarness.mutateTaskSyncSidecar(for: storeURL) { sidecar in
            sidecar["retiredClaudeTaskLists"] = state["retiredClaudeTaskLists"]
        }
    }

    func seedConfiguredTaskDestinations(
        count: Int,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        workspaceId: String,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var records: [String: [String: Any]] = [:]
        for index in 0..<count {
            let taskListID = "ArchivedList\(index)"
            records["\(taskStoreIdentity.rawValue):\(taskListID)"] = [
                "taskStoreIdentity": ["rawValue": taskStoreIdentity.rawValue],
                "taskListID": taskListID,
                "workspaceIDs": [workspaceId],
                "updatedAt": TimeInterval(index),
            ]
        }
        state["claudeTaskListDestinations"] = records
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
        try ClaudeHookLiveDeliveryHarness.mutateTaskSyncSidecar(for: storeURL) { sidecar in
            sidecar["claudeTaskListDestinations"] = state["claudeTaskListDestinations"]
        }
    }

    func reconcileRequests(in context: ClaudeHookLiveDeliveryHarness.Context) -> [[String: Any]] {
        ClaudeHookLiveDeliveryHarness.taskSyncReconcileRequests(in: context)
    }

    func feedEvent(_ line: String) -> [String: Any]? {
        guard let request = jsonObject(line),
              request["method"] as? String == "feed.push",
              let params = request["params"] as? [String: Any] else { return nil }
        return params["event"] as? [String: Any]
    }

    func jsonObject(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
