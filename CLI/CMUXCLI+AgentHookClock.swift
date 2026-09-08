import Foundation

extension CMUXCLI {
    static let stdinDrainingHookNoOpShellCommand = "cat >/dev/null 2>/dev/null || true; echo '{}'"

    static func shellNoOpSnippet(_ noOpCommand: String) -> String {
        let command = noOpCommand == "echo '{}'"
            ? stdinDrainingHookNoOpShellCommand
            : noOpCommand
        return "{ \(command); }"
    }
    static func agentHookCaptureTimeShell() -> String {
        // This shared clock is ordering authority across hook processes. Never
        // follow or write through a directory that is not private to this uid.
        [
            #"{ umask 077; export LC_ALL=C; fallback_capture_time() { exit 0; }; current_uid=`/usr/bin/id -u 2>/dev/null || true`;"#,
            #"prepare_clock_dir() { clock_candidate="$1"; if /bin/mkdir "$clock_candidate" 2>/dev/null; then :; elif [ -L "$clock_candidate" ] || ! [ -d "$clock_candidate" ]; then return 1; fi; clock_uid=`/usr/bin/stat -f %u "$clock_candidate" 2>/dev/null || true`; if [ "$clock_uid" != "$current_uid" ] || ! /bin/chmod 700 "$clock_candidate" 2>/dev/null; then return 1; fi; clock_uid=`/usr/bin/stat -f %u "$clock_candidate" 2>/dev/null || true`; clock_mode=`/usr/bin/stat -f %Lp "$clock_candidate" 2>/dev/null || true`; if [ -L "$clock_candidate" ] || ! [ -d "$clock_candidate" ] || [ "$clock_uid" != "$current_uid" ] || [ "$clock_mode" != 700 ]; then return 1; fi; clock_dir="$clock_candidate"; return 0; };"#,
            #"if ! [ "$current_uid" -ge 0 ] 2>/dev/null; then fallback_capture_time; fi; fallback_clock_dir="/tmp/cmux-agent-hook-clock-v2-$current_uid"; if [ -n "${TMPDIR:-}" ]; then primary_clock_dir="${TMPDIR%/}/cmux-agent-hook-clock-v2"; else primary_clock_dir="$fallback_clock_dir"; fi; if ! prepare_clock_dir "$primary_clock_dir"; then if [ "$primary_clock_dir" = "$fallback_clock_dir" ] || ! prepare_clock_dir "$fallback_clock_dir"; then fallback_capture_time; fi; fi;"#,
            // Pathname mode waits in the kernel; descriptor mode busy-spins on
            // supported macOS releases. Bound contention below hook deadlines.
            #"if /usr/bin/lockf -k -s -t 2 "$clock_dir/lock" /bin/sh -s -- "$clock_dir" <<'CMUX_AGENT_HOOK_CLOCK_BODY'"#,
            #"clock_dir="$1"; state="$clock_dir/state";"#,
            #"capture_file=`/usr/bin/mktemp "$clock_dir/capture.XXXXXX" 2>/dev/null || true`; captured_at=;"#,
            #"if [ -n "$capture_file" ] && [ -f "$capture_file" ]; then captured_at=`/usr/bin/stat -f %Fm "$capture_file" 2>/dev/null || true`; /bin/unlink "$capture_file" 2>/dev/null || true; fi;"#,
            #"formatted_at=; current_micros=; if [ -n "$captured_at" ]; then formatted_at=`printf "%.6f" "$captured_at" 2>/dev/null || true`; fi;"#,
            #"if [ -n "$formatted_at" ]; then epoch="${formatted_at%.*}"; fraction="${formatted_at#*.}"; if [ -n "$epoch" ] && [ -n "$fraction" ]; then case "$epoch" in *[!0-9]*) ;; *) case "$fraction" in *[!0-9]*) ;; *) current_micros=$((epoch * 1000000 + 1$fraction - 1000000));; esac;; esac; fi; fi;"#,
            #"if ! [ "$current_micros" -ge 0 ] 2>/dev/null; then date_bin="${CMUX_AGENT_HOOK_DATE_BIN:-/bin/date}"; epoch=`"$date_bin" +%s 2>/dev/null || printf 946684800`; case "$epoch" in *[!0-9]*|'') epoch=946684800;; esac; current_micros=$((epoch * 1000000)); fi; last_micros=;"#,
            #"if [ ! -L "$state" ] && [ -f "$state" ]; then IFS= read -r last_micros 2>/dev/null <"$state" || last_micros=; fi; if [ "$last_micros" -ge 946684800000000 ] 2>/dev/null && [ "$last_micros" -le 4102444800000000 ] 2>/dev/null && [ "$current_micros" -le "$last_micros" ] 2>/dev/null; then current_micros=$((last_micros + 1)); fi;"#,
            // Reserve whole milliseconds so journal precision cannot collapse
            // distinct hooks into an arrival-order tie.
            #"current_micros=$(((current_micros + 999) / 1000 * 1000));"#,
            #"state_committed=0; state_tmp=`/usr/bin/mktemp "$clock_dir/.state.XXXXXX" 2>/dev/null || true`; if [ -n "$state_tmp" ] && [ -f "$state_tmp" ]; then /bin/chmod 600 "$state_tmp" 2>/dev/null || true; if printf "%s\n" "$current_micros" >"$state_tmp" && /bin/mv -f "$state_tmp" "$state" 2>/dev/null; then state_tmp=; state_committed=1; fi; if [ -n "$state_tmp" ]; then /bin/rm -f "$state_tmp" 2>/dev/null || true; fi; fi; if [ "$state_committed" != 1 ]; then exit 1; fi;"#,
            #"seconds=$((current_micros / 1000000)); micros=$((current_micros % 1000000)); printf "%s.%06d" "$seconds" "$micros""#,
            "CMUX_AGENT_HOOK_CLOCK_BODY",
            "then exit 0; fi;",
            #"fallback_capture_time; }"#,
        ].joined(separator: "\n")
    }

    static func timestampedAgentHookInvocation(
        executable: String,
        arguments: String,
        noOpSnippet: String
    ) -> String {
        let captureTime = agentHookCaptureTimeShell()
        let quotedCaptureTime = shellSingleQuote(captureTime)
        return "hook_captured_at=\"$(/bin/sh -c \(quotedCaptureTime))\"; if [ -n \"$hook_captured_at\" ]; then CMUX_AGENT_HOOK_CAPTURED_AT=\"$hook_captured_at\" \(executable) \(arguments); else \(noOpSnippet); fi"
    }

    /// Permission/decision hooks must still run when the ordering clock is
    /// unavailable. They explicitly publish an empty event-time environment in
    /// that case (so the receiver fails closed for ordered state), but preserve
    /// the command's exit status so a denial cannot silently become an allow.
    private static func timestampedAgentHookInvocationPreservingExit(
        executable: String,
        arguments: String
    ) -> String {
        let captureTime = agentHookCaptureTimeShell()
        let quotedCaptureTime = shellSingleQuote(captureTime)
        return "hook_captured_at=\"$(/bin/sh -c \(quotedCaptureTime))\"; if [ -n \"$hook_captured_at\" ]; then CMUX_AGENT_HOOK_CAPTURED_AT=\"$hook_captured_at\" \(executable) \(arguments); else CMUX_AGENT_HOOK_CAPTURED_AT=\"\" \(executable) \(arguments); fi"
    }

    static func agentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'"
    ) -> String {
        if case .pinned = def.dispatch {
            return pinnedAgentHookShellCommand(command, for: def, noOpCommand: noOpCommand)
        }
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        let socketInvocation = timestampedAgentHookInvocation(
            executable: #""$cmux_cli""#,
            arguments: #"--socket "$CMUX_SOCKET_PATH" \#(routedArguments)"#,
            noOpSnippet: noOpSnippet
        )
        let directInvocation = timestampedAgentHookInvocation(
            executable: #""$cmux_cli""#,
            arguments: routedArguments,
            noOpSnippet: noOpSnippet
        )
        return "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then { if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \(socketInvocation); else \(directInvocation); fi; } || \(noOpSnippet); else \(noOpSnippet); fi"
    }

    /// Synchronous Codex lifecycle hook command. Capturing the callback's
    /// parent PID before dispatch prevents a descendant from reusing an
    /// inherited `CMUX_CODEX_PID` as its own owner identity.
    static func codexSynchronousAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef
    ) -> String {
        let dispatch = agentHookShellCommand(command, for: def)
        return "CMUX_CODEX_HOOK_PID=\"${PPID:-}\"; export CMUX_CODEX_HOOK_PID; \(dispatch)"
    }

    static func exitTwoPropagatingAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'"
    ) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        let socketInvocation = timestampedAgentHookInvocationPreservingExit(
            executable: #""$cmux_cli""#,
            arguments: #"--socket "$CMUX_SOCKET_PATH" \#(routedArguments)"#
        )
        let directInvocation = timestampedAgentHookInvocationPreservingExit(
            executable: #""$cmux_cli""#,
            arguments: routedArguments
        )
        return "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \(socketInvocation); else \(directInvocation); fi; status=$?; if [ \"$status\" -eq 2 ]; then exit 2; fi; if [ \"$status\" -ne 0 ]; then \(noOpSnippet); fi; else \(noOpSnippet); fi"
    }

}
