import Foundation

struct ClaudeHookActiveSessionRecord: Codable {
    var sessionId: String
    var turnId: String?
    var allowsNewSessionReplacement: Bool?
    var updatedAt: TimeInterval
}

typealias AgentHookLaunchCommandRecord = AgentLaunchCommand

struct CodexMonitorLeaseRecord: Codable {
    var leaseId: String
    var sessionId: String
    var turnId: String?
    var workspaceId: String
    var surfaceId: String?
    var createdAt: TimeInterval
    var retiredAt: TimeInterval?
}
