import Foundation

extension RemoteResumeBindingTests {
    func remoteResumeParams(
        workspaceID: UUID,
        surfaceID: UUID,
        command: String
    ) -> [String: Any] {
        [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "name": "Codex",
            "kind": "codex",
            "checkpoint_id": "session-remote-7989",
            "source": "agent-hook",
            "agent_event_time": 1_893_456_700,
            "command": command,
            "cwd": "/srv/remote project",
            "environment": [
                "REMOTE_FLAG": "value with spaces",
                "ANTHROPIC_API_KEY": "must-not-persist",
            ],
            "auto_resume": true,
        ]
    }
}
