import CMUXAgentLaunch
import Foundation
import Testing

extension ClaudeAutomaticTeamTaskSyncHookTests {
    func runHook(
        context: ClaudeHookLiveDeliveryHarness.Context,
        environment: [String: String],
        sessionId: String,
        agentID: String? = nil,
        toolName: String = "TaskUpdate",
        standardInput: String? = nil
    ) -> ClaudeHookLiveDeliveryHarness.ProcessRunResult {
        let defaultInput: String
        if let agentID {
            defaultInput = #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","agent_id":"\#(agentID)","tool_name":"\#(toolName)","tool_input":{"taskId":"1","status":"in_progress"}}"#
        } else {
            defaultInput = #"{"session_id":"\#(sessionId)","hook_event_name":"PostToolUse","tool_name":"\#(toolName)","tool_input":{"taskId":"1","status":"in_progress"}}"#
        }
        return ClaudeHookLiveDeliveryHarness.runHookProcess(
            context: context,
            arguments: ["hooks", "claude", "task-sync"],
            environment: environment,
            standardInput: standardInput ?? defaultInput
        )
    }

    func writeTeamConfig(
        name: String,
        leaderSessionID: String?,
        agentID: String,
        additionalAgentIDs: [String] = [],
        to directory: URL
    ) throws {
        var value: [String: Any] = [
            "name": name,
            "members": ([agentID] + additionalAgentIDs).map { ["agentId": $0] },
        ]
        if let leaderSessionID {
            value["leadAgentId"] = agentID
            value["leadSessionId"] = leaderSessionID
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("config.json"))
    }

    func writeTask(_ json: String, to directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("1.json"))
    }

    func reconcileRequests(
        in context: ClaudeHookLiveDeliveryHarness.Context
    ) -> [[String: Any]] {
        ClaudeHookLiveDeliveryHarness.taskSyncReconcileRequests(in: context)
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

    func teamBindingRecords(
        in storeURL: URL
    ) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: storeURL)
        let state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return state["claudeTeamTaskBindings"] as? [String: [String: Any]] ?? [:]
    }

    func rewriteTeamBindingAsLegacy(
        taskListID: String,
        storeURL: URL
    ) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let bindings = try #require(
            state["claudeTeamTaskBindings"] as? [String: [String: Any]]
        )
        var record = try #require(bindings.values.first)
        var binding = try #require(record["binding"] as? [String: Any])
        binding.removeValue(forKey: "taskStoreIdentity")
        record["binding"] = binding
        state["claudeTeamTaskBindings"] = [taskListID: record]
        let legacyData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try legacyData.write(to: storeURL)
        try ClaudeHookLiveDeliveryHarness.mutateTaskSyncSidecar(for: storeURL) { sidecar in
            sidecar["claudeTeamTaskBindings"] = state["claudeTeamTaskBindings"]
        }
    }

    func removeTeamBindingRecords(storeURL: URL) throws {
        let data = try Data(contentsOf: storeURL)
        var state = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        state["claudeTeamTaskBindings"] = [String: [String: Any]]()
        let updatedData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: storeURL)
        try ClaudeHookLiveDeliveryHarness.mutateTaskSyncSidecar(for: storeURL) { sidecar in
            sidecar["claudeTeamTaskBindings"] = state["claudeTeamTaskBindings"]
        }
    }

    func rewriteTeamConfigGeneration(at directory: URL) throws {
        let configURL = directory.appendingPathComponent("config.json")
        var config = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        )
        config["generationMarker"] = UUID().uuidString
        let updatedData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: configURL)
    }
}
