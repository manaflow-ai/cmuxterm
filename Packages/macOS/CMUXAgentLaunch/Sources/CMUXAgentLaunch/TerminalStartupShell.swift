import Foundation

public enum TerminalStartupShellQuoting {
    public static func singleQuoted(_ value: String) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellToken(_ value: String, allowingBareASCII: Bool) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        if allowingBareASCII,
           value.range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return value
        }
        return singleQuoted(value)
    }

    private static func asciiPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        // Keep the command substitution inside one double-quoted shell word;
        // otherwise spaces in localized notices are field-split by the shell.
        return "\"$(printf '" + octalBytes + "')\""
    }
}

/// Which syntax family the user's interactive shell parses. Everything cmux
/// generates is POSIX; nushell is the one supported login shell that cannot
/// parse it (see ``NushellTypedShellCommand``).
public enum TerminalStartupShellDialect: Equatable, Sendable {
    case posix
    case nushell

    /// Maps a shell executable path to its dialect by basename. Everything
    /// except `nu` is treated as POSIX: every other login shell cmux supports
    /// (zsh/bash/fish/csh/dash/ksh) parses the POSIX command strings cmux
    /// generates.
    public static func forShellPath(_ shell: String?) -> TerminalStartupShellDialect {
        guard let shell = shell?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shell.isEmpty else {
            return .posix
        }
        return URL(fileURLWithPath: shell).lastPathComponent == "nu" ? .nushell : .posix
    }

    /// Dialect of the login shell cmux spawns terminal surfaces with — the
    /// same `$SHELL` fallback chain the spawn path uses.
    public static var loginShell: TerminalStartupShellDialect {
        forShellPath(ProcessInfo.processInfo.environment["SHELL"])
    }

    /// Dialect for input typed into a remote host's shell after attach.
    /// cmux does not (yet) know the remote login shell — the SSH bootstrap
    /// resolves `$SHELL` on the host at runtime and nothing reports it back —
    /// so remote input stays POSIX, which is what cmux has always sent to
    /// remotes. If the bootstrap ever reports the remote shell, this is the
    /// single seam to replace with real detection.
    public static let remoteHost: TerminalStartupShellDialect = .posix
}

/// Final rendering step for cmux-generated POSIX one-liners that get typed
/// into (or pasted into) the user's interactive shell. POSIX shells receive
/// the command verbatim; nushell receives it delegated through `/bin/sh`.
/// Launcher-script inputs (`/bin/zsh '<script>'`) parse in every supported
/// shell and do not need this.
public struct TerminalStartupTypedShellCommand {
    /// Dialect of the shell that will parse the rendered input.
    public let dialect: TerminalStartupShellDialect

    /// Defaults to the login shell cmux spawns local surfaces with; pass
    /// ``TerminalStartupShellDialect/remoteHost`` when the input is typed
    /// into a remote host's shell instead.
    public init(dialect: TerminalStartupShellDialect = .loginShell) {
        self.dialect = dialect
    }

    /// Renders `posixCommand` for typing: verbatim for POSIX shells,
    /// delegated through `/bin/sh` for nushell (which cannot parse POSIX).
    public func typedInput(posixCommand: String) -> String {
        switch dialect {
        case .posix:
            return posixCommand
        case .nushell:
            return NushellTypedShellCommand().wrapping(posixCommand: posixCommand)
        }
    }
}

