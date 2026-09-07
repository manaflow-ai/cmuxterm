/// Ordered outcomes and measurements from one batch execution.
public struct CmuxRPCBatchReport {
    /// JSON-compatible records containing ID, method, status, duration, and result or error.
    public let records: [[String: Any]]
    /// Number of actual transport calls, excluding unresolved or skipped requests.
    public let attempted: Int
    /// Number of successful transport calls.
    public let succeeded: Int
    /// Total execution time in milliseconds, excluding input parsing and connection setup.
    public let durationMilliseconds: Double

    /// Whether every planned request completed successfully.
    public var ok: Bool { succeeded == records.count }

    /// A JSON-compatible report that keeps original server result IDs intact.
    public var jsonObject: [String: Any] {
        [
            "ok": ok,
            "results": records,
            "metrics": [
                "requests": records.count,
                "attempted": attempted,
                "succeeded": succeeded,
                "failed": records.filter { $0["status"] as? String == "failed" }.count,
                "skipped": records.filter { $0["status"] as? String == "skipped" }.count,
                "duration_ms": durationMilliseconds,
            ],
        ]
    }
}
