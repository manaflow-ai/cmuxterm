import CMUXAgentLaunch
import Foundation
import CmuxCore
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session persistence working-directory policy")
struct SessionPersistenceWorkingDirectoryPolicyTests {
    @Test("Drops duplicate Kimi working-directory options")
    func dropsDuplicateKimiWorkingDirectoryOption() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "cd '/tmp/project' && kimi --resume session --work-dir '/tmp/project' --model kimi-k2",
            cwd: "/tmp/project",
            source: "agent-hook",
            updatedAt: 1
        )

        #expect(
            binding.command == TerminalStartupWorkingDirectoryPrefix.prefix(
                "kimi --resume session --model kimi-k2",
                workingDirectory: "/tmp/project"
            )
        )
    }

    @Test("Drops Kimi and Qoder short working-directory options")
    func dropsKimiAndQoderShortWorkingDirectoryOptions() {
        let workingDirectory = "/tmp/project"
        let cases = [
            (kind: "kimi", option: "-w '\(workingDirectory)'"),
            (kind: "kimi", option: "-w\(workingDirectory)"),
            (kind: "qoder", option: "-w '\(workingDirectory)'"),
            (kind: "qoder", option: "-w\(workingDirectory)"),
        ]

        for item in cases {
            let binding = SurfaceResumeBindingSnapshot(
                kind: item.kind,
                command: "cd '\(workingDirectory)' && \(item.kind) --resume session \(item.option) --model fast",
                cwd: workingDirectory,
                source: "agent-hook",
                updatedAt: 1
            )

            #expect(
                binding.command == TerminalStartupWorkingDirectoryPrefix.prefix(
                    "\(item.kind) --resume session --model fast",
                    workingDirectory: workingDirectory
                ),
                Comment(rawValue: "\(item.kind) \(item.option)")
            )
        }
    }

    @Test("Drops Kimi and Qoder short options after cwd retargeting")
    func retargetingDropsKimiAndQoderShortWorkingDirectoryOptions() {
        let workingDirectory = "/tmp/project"
        let cases = [
            (kind: "kimi", option: "-w '\(workingDirectory)'"),
            (kind: "kimi", option: "-w\(workingDirectory)"),
            (kind: "qoder", option: "-w '\(workingDirectory)'"),
            (kind: "qoder", option: "-w\(workingDirectory)"),
        ]

        for item in cases {
            let binding = SurfaceResumeBindingSnapshot(
                kind: item.kind,
                command: "\(item.kind) --resume session \(item.option) --model fast",
                cwd: nil,
                source: "agent-hook",
                updatedAt: 1
            )
            let retargeted = binding.retargetingWorkingDirectory(workingDirectory)

            #expect(
                retargeted.command == TerminalStartupWorkingDirectoryPrefix.prefix(
                    "\(item.kind) --resume session --model fast",
                    workingDirectory: workingDirectory
                ),
                Comment(rawValue: "\(item.kind) \(item.option)")
            )
        }
    }

    @Test("Preserves Claude Teams worktree options")
    func preservesClaudeTeamsWorktreeOption() {
        let workingDirectory = "/tmp/team-worktree"
        let command = "cmux claude-teams --resume team-session -w '\(workingDirectory)' --model sonnet"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "cd '\(workingDirectory)' && \(command)",
            cwd: workingDirectory,
            source: "agent-hook",
            updatedAt: 1
        )

        #expect(
            binding.command == TerminalStartupWorkingDirectoryPrefix.optionalChangeDirectoryPrefix(
                for: workingDirectory
            ).map { $0 + command }
        )
    }
}
