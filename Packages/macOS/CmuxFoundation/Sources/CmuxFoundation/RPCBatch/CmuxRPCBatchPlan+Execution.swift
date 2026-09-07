extension CmuxRPCBatchPlan {
    /// Executes ordered requests without retrying, rolling back, or opening connections.
    ///
    /// The synchronous transport closure fits the CLI's existing request-response loop;
    /// it is an injected operation, not an asynchronous completion handler. A lost
    /// response always stops execution because the server may already have applied it.
    ///
    /// - Parameters:
    ///   - continueOnError: Continue independent requests after complete server errors or missing references.
    ///   - now: A monotonic clock returning seconds; tests may inject a deterministic clock.
    ///   - send: An operation using an already-authenticated connection. Throw
    ///     ``CmuxRPCBatchCallFailure`` to classify reusable server failures.
    /// - Returns: Every request's outcome, including skipped requests after a failure.
    public func execute(
        continueOnError: Bool = false,
        now: () -> Double,
        send: (String, [String: Any]) throws -> [String: Any]
    ) -> CmuxRPCBatchReport {
        let start = now()
        var results: [String: [String: Any]] = [:]
        var records: [[String: Any]] = []
        var stopped = false
        var attempted = 0
        var succeeded = 0
        for (index, request) in requests.enumerated() {
            var record: [String: Any] = ["id": request.id, "method": request.method]
            if stopped {
                record["status"] = "skipped"
                record["duration_ms"] = 0
                records.append(record)
                continue
            }
            let requestStart = now()
            do {
                guard let params = try resolve(request.params, results: results, index: index) as? [String: Any] else {
                    throw CmuxRPCBatchError(.unresolvedReference, index: index)
                }
                attempted += 1
                let result = try send(request.method, params)
                results[request.id] = result
                record["status"] = "succeeded"
                record["result"] = result
                succeeded += 1
            } catch let error as CmuxRPCBatchError {
                record["status"] = "failed"
                record["error"] = ["code": error.code.rawValue]
                stopped = !continueOnError
            } catch let error as CmuxRPCBatchCallFailure {
                record["status"] = "failed"
                record["error"] = ["code": error.code, "message": error.message]
                stopped = !continueOnError || !error.canContinue
            } catch {
                record["status"] = "failed"
                record["error"] = ["code": "transport_error"]
                stopped = true
            }
            record["duration_ms"] = max(0, now() - requestStart) * 1000
            records.append(record)
        }
        return CmuxRPCBatchReport(
            records: records, attempted: attempted, succeeded: succeeded,
            durationMilliseconds: max(0, now() - start) * 1000
        )
    }
}
