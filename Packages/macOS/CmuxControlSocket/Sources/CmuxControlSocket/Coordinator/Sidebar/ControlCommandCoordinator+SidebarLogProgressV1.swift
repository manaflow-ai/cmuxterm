internal import Foundation


/// Log and progress sidebar command handlers.
extension ControlCommandCoordinator {
    nonisolated func sidebarAppendLog(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard context?.controlSidebarIsValidLogLevel(levelStr) ?? false else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]
        let tabArg = parsed.options["tab"]

        let appended = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarAppendLog(
                    tabArg: tabArg,
                    message: message,
                    levelRawValue: levelStr,
                    source: source
                )
            }
        } ?? false
        guard appended else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_log` — clear the sidebar log (one resolution hop).
    nonisolated func sidebarClearLog(_ args: String, context: (any ControlCommandContext)?) -> String {
        let tabArg = sidebarParseOptions(args).options["tab"]
        let cleared = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarClearLog(tabArg: tabArg) }
        } ?? false
        guard cleared else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }

    /// `list_log` — list sidebar log entries (limit parse, suffix slice, and
    /// line formatting off-main around one snapshot hop).
    nonisolated func sidebarListLog(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        var limit: Int?
        if let limitStr = parsed.options["limit"] {
            if limitStr.isEmpty {
                return "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]"
            }
            guard let parsedLimit = Int(limitStr), parsedLimit >= 0 else {
                return "ERROR: Invalid limit '\(limitStr)' — must be >= 0"
            }
            limit = parsedLimit
        }

        let tabArg = parsed.options["tab"]
        let snapshot = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarLogEntries(tabArg: tabArg) }
        } ?? nil
        guard let allEntries = snapshot else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        if allEntries.isEmpty {
            return "No log entries"
        }
        let entries: [ControlSidebarLogEntrySnapshot]
        if let limit {
            entries = Array(allEntries.suffix(limit))
        } else {
            entries = allEntries
        }
        return entries.map { entry in
            var line = "[\(entry.levelRawValue)] \(entry.message)"
            if let source = entry.source, !source.isEmpty {
                line = "[\(source)] \(line)"
            }
            return line
        }.joined(separator: "\n")
    }

    /// `set_progress` — set the sidebar progress bar (value parse/clamp
    /// off-main, one resolution hop for the write).
    nonisolated func sidebarSetProgress(_ args: String, context: (any ControlCommandContext)?) -> String {
        let parsed = sidebarParseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]
        let tabArg = parsed.options["tab"]

        let applied = context.map { seam in
            seam.controlSidebarOnMain {
                $0.controlSidebarSetProgress(tabArg: tabArg, value: clamped, label: label)
            }
        } ?? false
        guard applied else {
            return parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
        }
        return "OK"
    }

    /// `clear_progress` — clear the sidebar progress bar (one resolution hop).
    nonisolated func sidebarClearProgress(_ args: String, context: (any ControlCommandContext)?) -> String {
        let tabArg = sidebarParseOptions(args).options["tab"]
        let cleared = context.map { seam in
            seam.controlSidebarOnMain { $0.controlSidebarClearProgress(tabArg: tabArg) }
        } ?? false
        guard cleared else {
            return "ERROR: Tab not found"
        }
        return "OK"
    }
}
