import Foundation

/// Types one localized explanation into a restored terminal as a single shell
/// command, so the pane says why cmux did not resume an agent session there.
public struct AgentRestoreNoticeInput: Sendable {
    public let message: String

    public init(message: String) { self.message = message }

    /// Renders the notice for the shell that will parse it. The message stays
    /// one single-quoted argument, so spaces and non-ASCII text survive intact.
    public func startupInput(dialect: TerminalStartupShellDialect) -> String {
        let command = "/usr/bin/printf '%s\\n' " +
            TerminalStartupShellQuoting.singleQuoted(message)
        return " " + TerminalStartupTypedShellCommand(dialect: dialect)
            .typedInput(posixCommand: command) + "\n"
    }
}
