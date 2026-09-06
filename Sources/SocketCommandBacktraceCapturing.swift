/// Captures a diagnostic stack when a socket command exceeds the watchdog.
protocol SocketCommandBacktraceCapturing: Sendable {
    func captureBacktrace() -> [String]
}
