import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxCore
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Compatibility fallbacks must quote identifiers before a rendered command
/// is typed into a terminal, even when a structured restore snapshot is absent.
@MainActor
@Suite(.serialized)
struct VaultRestoreCompatibilitySecurityTests {
    @Test("Quoted registration values remain structured through the app adapter")
    func quotedRegistrationValueRemainsAvailable() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "custom-agent",
            name: "Custom Agent",
            detect: CmuxVaultAgentDetectRule(processName: "custom-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --label ' padded ' --session {{sessionId}}",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "custom-agent:quoted-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "quoted-session",
            title: "Quoted argument",
            cwd: "/tmp/project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_108),
            fileURL: nil,
            specifics: .registered(registration)
        )
        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)

        #expect(launch.strategy == .restoreVerb)
        #expect(launch.initialInput == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore custom-agent quoted-session\n")
        #expect(snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ) == ["custom-agent", "--label", " padded ", "--session", "quoted-session"])
    }

    @Test(arguments: ["claude", "codex"])
    func invalidBuiltInSessionIDsAreQuotedInCompatibilityInput(_ rawKind: String) throws {
        let unsafeSessionID = "bad;echo-pwned"
        let specifics: AgentSpecifics = rawKind == "claude"
            ? .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
            : .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        let entry = SessionEntry(
            id: "\(rawKind):\(unsafeSessionID)",
            agent: rawKind == "claude" ? .claude : .codex,
            sessionId: unsafeSessionID,
            title: "Unsafe \(rawKind) session",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_107),
            fileURL: nil,
            specifics: specifics
        )
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .legacyCommand)
        #expect(launch.legacyFallbackReason == .missingStructuredSnapshot)
        #expect(!launch.initialInput.contains("--resume \(unsafeSessionID)"))
        #expect(!launch.initialInput.contains("resume \(unsafeSessionID)"))
    }
}
