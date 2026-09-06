import Foundation

/// Process identity evidence collected while diagnosing a Codex writer lock.
public struct CodexWriterProcessEvidence: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let startTime: String?
    public let command: String

    public init(pid: Int32, parentPID: Int32, command: String, startTime: String? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTime = startTime
        self.command = command
    }

    public var appServerPort: Int? {
        guard isCodexAppServer else { return nil }
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let endpoint = optionValue(named: "--listen", in: parts) else {
            return nil
        }
        return Self.port(from: endpoint)
    }

    public var watcherAppServerPort: Int? {
        guard command.contains("__codex-teams-watch") else { return nil }
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let endpoint = optionValue(named: "--app-server-url", in: parts) else {
            return nil
        }
        return Self.port(from: endpoint)
    }

    public var isCodexAppServer: Bool {
        let parts = command.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard parts.contains("app-server") else { return false }
        return parts.contains {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasPrefix("codex")
        }
    }

    private func optionValue(named name: String, in parts: [String]) -> String? {
        if let inline = parts.first(where: { $0.hasPrefix(name + "=") }) {
            return String(inline.dropFirst(name.count + 1))
        }
        guard let index = parts.firstIndex(of: name), index + 1 < parts.count else {
            return nil
        }
        return parts[index + 1]
    }

    private static func port(from endpoint: String) -> Int? {
        guard let components = URLComponents(string: endpoint),
              let port = components.port,
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }
}

/// Classifies a holder without applying a termination policy.
public struct CodexWriterRecoveryAssessment: Equatable, Sendable {
    public enum Classification: Equatable, Sendable {
        case orphanedAppServer
        case ownedAppServer
        case other
    }

    public let holder: CodexWriterProcessEvidence
    public let classification: Classification

    public init(holder: CodexWriterProcessEvidence, watchedAppServerPorts: Set<Int>) {
        self.holder = holder
        if holder.isCodexAppServer,
           holder.parentPID == 1,
           let port = holder.appServerPort,
           !watchedAppServerPorts.contains(port) {
            classification = .orphanedAppServer
        } else if holder.isCodexAppServer {
            classification = .ownedAppServer
        } else {
            classification = .other
        }
    }
}
