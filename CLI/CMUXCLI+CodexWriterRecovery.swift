import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func runCodexWriterRecovery(commandArgs: [String]) throws {
        guard commandArgs.first?.lowercased() == "recover",
              let sessionID = CodexWriterRecovery.resumeSessionID(arguments: commandArgs) else {
            throw CLIError(message: Self.codexWriterRecoveryUsage())
        }
        let confirms = commandArgs.contains { $0 == "--yes" || $0 == "-y" }
        let environment = ProcessInfo.processInfo.environment
        let codexHome = CodexWriterRecovery.codexHomeOverride(arguments: commandArgs)
            ?? CodexHomeResolver().resolve(
                ambientEnvironment: environment,
                fallbackHomeDirectory: NSHomeDirectory()
            )
        let recovery = CodexWriterRecovery()
        let report = recovery.inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state != .unavailable else {
            throw CLIError(message: Self.codexWriterUnavailableMessage(sessionID: sessionID, lockPath: report.lock.lockPath))
        }
        guard report.lock.state == .active else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.notBlocked", defaultValue: "Codex thread %@ is not currently blocked by an active local writer lock."),
                sessionID
            ))
        }
        guard let orphan = report.orphanedHolder else {
            throw CLIError(message: Self.codexWriterReportMessage(sessionID: sessionID, report: report))
        }
        guard confirms else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.confirm", defaultValue: "This will terminate orphaned Codex app-server PID %d. Re-run with --yes to continue."),
                orphan.pid
            ))
        }
        guard recovery.terminateOrphanedHolder(
            sessionID: sessionID,
            codexHome: codexHome,
            pid: orphan.pid
        ) else {
            let refreshedReport = recovery.inspect(sessionID: sessionID, codexHome: codexHome)
            switch refreshedReport.lock.state {
            case .unavailable:
                throw CLIError(message: Self.codexWriterUnavailableMessage(
                    sessionID: sessionID,
                    lockPath: refreshedReport.lock.lockPath
                ))
            case .available:
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.codex.writer.recovery.notBlocked", defaultValue: "Codex thread %@ is not currently blocked by an active local writer lock."),
                    sessionID
                ))
            case .active:
                throw CLIError(message: Self.codexWriterReportMessage(
                    sessionID: sessionID,
                    report: refreshedReport
                ))
            }
        }
        print(String.localizedStringWithFormat(
            String(localized: "cli.codex.writer.recovery.terminated", defaultValue: "Terminated orphaned Codex app-server PID %d for thread %@. Retry resume."),
            orphan.pid,
            sessionID
        ))
    }

    func guardCodexWriterBeforeResume(
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws {
        guard !CodexWriterRecovery.usesRemoteProvider(arguments: arguments),
              let sessionID = CodexWriterRecovery.codexResumeSessionID(arguments: arguments) else {
            return
        }
        let codexHome = CodexHomeResolver().resolve(
            launchEnvironment: environment,
            launchWorkingDirectory: workingDirectory,
            ambientEnvironment: environment,
            fallbackHomeDirectory: NSHomeDirectory()
        )
        let report = CodexWriterRecovery().inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state != .unavailable else {
            throw CLIError(message: Self.codexWriterUnavailableMessage(sessionID: sessionID, lockPath: report.lock.lockPath))
        }
        guard report.lock.state == .active else { return }
        throw CLIError(message: Self.codexWriterReportMessage(sessionID: sessionID, report: report))
    }

    static func codexWriterRecoveryUsage() -> String {
        String(localized: "cli.codex.writer.recovery.usageWithHome", defaultValue: "Usage: cmux codex-teams recover <thread-id> [--codex-home <path>] [--yes]\n\nInspect the local Codex writer lock and, with --yes, terminate only a holder proven to be an orphaned app-server.")
    }

    static func codexWriterUnavailableMessage(sessionID: String, lockPath: String) -> String {
        String.localizedStringWithFormat(
            String(localized: "cli.codex.writer.recovery.unavailable", defaultValue: "cmux could not safely inspect the Codex writer lock for thread %@. No process was started or terminated. Lock: %@"),
            sessionID,
            lockPath
        )
    }

    static func codexWriterReportMessage(sessionID: String, report: CodexWriterRecoveryReport) -> String {
        let lock = report.lock.lockPath
        if let holder = report.orphanedHolder,
           let assessment = report.assessments.first(where: { $0.holder.pid == holder.pid }),
           assessment.classification == .orphanedAppServer {
            return String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.orphaned", defaultValue: "Codex thread %@ is blocked by an orphaned app-server (PID %d, parent PID %d, executable %@). Run `cmux codex-teams recover %@ --yes`, then retry resume. Lock: %@"),
                sessionID,
                holder.pid,
                holder.parentPID,
                holder.validatedExecutableName
                    ?? String(localized: "cli.codex.writer.recovery.unknownExecutable", defaultValue: "unidentified process"),
                sessionID,
                lock
            )
        }
        let ownerText = report.holders.map {
            String.localizedStringWithFormat(
                String(localized: "cli.codex.writer.recovery.owner", defaultValue: "PID %d, parent PID %d, executable %@"),
                $0.pid,
                $0.parentPID,
                $0.validatedExecutableName
                    ?? String(localized: "cli.codex.writer.recovery.unknownExecutable", defaultValue: "unidentified process")
            )
        }.joined(separator: String(localized: "cli.codex.writer.recovery.ownerSeparator", defaultValue: "; "))
        return String.localizedStringWithFormat(
            String(localized: "cli.codex.writer.recovery.active", defaultValue: "Codex thread %@ already has an active writer (%@). Continue in the owning Codex session, then retry. cmux will not terminate it. Lock: %@"),
            sessionID,
            ownerText.isEmpty
                ? String(localized: "cli.codex.writer.recovery.unknownHolder", defaultValue: "unknown holder")
                : ownerText,
            lock
        )
    }

    static func codexWriterReportMessage(
        sessionID: String,
        codexHome: String
    ) -> String? {
        let report = CodexWriterRecovery().inspect(sessionID: sessionID, codexHome: codexHome)
        guard report.lock.state == .active else { return nil }
        return Self.codexWriterReportMessage(sessionID: sessionID, report: report)
    }
}
