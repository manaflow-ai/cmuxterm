import Darwin
import Foundation

/// Shared ownership inspection and explicit orphan termination policy.
public struct CodexWriterRecovery: Sendable {
    private let lockInspector: CodexWriterLockInspector

    public init() {
        lockInspector = CodexWriterLockInspector()
    }

    public func inspect(sessionID: String, codexHome: String) -> CodexWriterRecoveryReport {
        let lock = lockInspector.inspect(sessionID: sessionID, codexHome: codexHome)
        guard lock.state == .active else {
            return CodexWriterRecoveryReport(
                lock: lock,
                holders: [],
                assessments: [],
                processScanIsComplete: true
            )
        }
        let scan = processScan(lockPath: lock.lockPath)
        let watchedPorts = scan.watchedAppServerPorts
        let assessments = scan.processes.map {
            CodexWriterRecoveryAssessment(holder: $0, watchedAppServerPorts: watchedPorts)
        }
        return CodexWriterRecoveryReport(
            lock: lock,
            holders: scan.processes,
            assessments: assessments,
            processScanIsComplete: scan.isComplete
        )
    }

    public func terminateOrphanedHolder(
        sessionID: String,
        codexHome: String,
        pid: Int32
    ) -> Bool {
        let initial = inspect(sessionID: sessionID, codexHome: codexHome)
        guard initial.lock.state == .active,
              initial.processScanIsComplete,
              initial.orphanedHolder?.pid == pid,
              let initialAssessment = initial.assessments.first(where: { $0.holder.pid == pid }) else {
            return false
        }
        let current = inspect(sessionID: sessionID, codexHome: codexHome)
        guard current.lock == initial.lock,
              current.processScanIsComplete,
              current.orphanedHolder?.pid == pid,
              let currentAssessment = current.assessments.first(where: { $0.holder.pid == pid }),
              currentAssessment.holder == initialAssessment.holder,
              kill(pid, 0) == 0 else {
            return false
        }
        return kill(pid, SIGTERM) == 0
    }

    public static func resumeSessionID(arguments: [String]) -> String? {
        guard let commandIndex = arguments.firstIndex(where: {
            let value = $0.lowercased()
            return value == "resume" || value == "recover"
        }) else {
            return nil
        }
        return arguments.dropFirst(commandIndex + 1).compactMap { argument in
            UUID(uuidString: argument)?.uuidString.lowercased()
        }.first
    }

    public static func codexHomeOverride(arguments: [String]) -> String? {
        guard arguments.first?.lowercased() == "recover",
              let index = arguments.firstIndex(of: "--codex-home"),
              index + 1 < arguments.count else {
            return nil
        }
        let path = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public static func usesRemoteProvider(arguments: [String]) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument == "--remote" || argument.hasPrefix("--remote=") { return true }
            index += 1
        }
        return false
    }

    public static func isWriterConflict(code: Int?, message: String?) -> Bool {
        guard code == -32600, let message else { return false }
        let normalized = message
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.contains("already has an active writer")
    }

    public static func codexResumeSessionID(arguments: [String]) -> String? {
        guard let executable = arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "codex",
              arguments.dropFirst().first?.lowercased() == "resume" else {
            return nil
        }
        return arguments.dropFirst(2).compactMap { argument in
            UUID(uuidString: argument)?.uuidString.lowercased()
        }.first
    }

    private func processScan(lockPath: String) -> (
        processes: [CodexWriterProcessEvidence],
        watchedAppServerPorts: Set<Int>,
        isComplete: Bool
    ) {
        guard let lsofOutput = commandOutput(path: "/usr/sbin/lsof", arguments: ["-n", "-w", "-Fpc", lockPath]) else {
            return ([], [], false)
        }
        let lsofPIDs = Set(lsofOutput.split(whereSeparator: \.isNewline).compactMap { line -> Int32? in
            guard line.first == "p" else { return nil }
            return Int32(line.dropFirst())
        })
        guard !lsofPIDs.isEmpty,
              let psOutput = commandOutput(path: "/bin/ps", arguments: ["-ww", "-axo", "pid=,ppid=,lstart=,command="]) else {
            return ([], [], false)
        }
        var allProcesses: [CodexWriterProcessEvidence] = []
        var parsedPIDs = Set<Int32>()
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 8,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]) else {
                continue
            }
            parsedPIDs.insert(pid)
            let startTime = fields[2..<7].joined(separator: " ")
            allProcesses.append(CodexWriterProcessEvidence(
                pid: pid,
                parentPID: parentPID,
                command: fields.dropFirst(7).joined(separator: " "),
                startTime: startTime,
                executablePath: lsofPIDs.contains(pid) ? executablePath(for: pid) : nil
            ))
        }
        let processes = allProcesses.filter { lsofPIDs.contains($0.pid) }
        return (
            processes,
            Set(allProcesses.compactMap(\.watcherAppServerPort)),
            parsedPIDs.isSuperset(of: lsofPIDs) && processes.count == lsofPIDs.count
        )
    }

    private func commandOutput(path: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func executablePath(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid_t(pid), rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
