import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Preflight runs before socket discovery, authentication, or window routing.
    func prepareRPCBatch(commandArgs: [String], windowID: String?, idFormat: String?) throws
        -> (plan: CmuxRPCBatchPlan, continueOnError: Bool, dryRun: Bool) {
        guard windowID == nil, idFormat == nil else {
            throw CLIError(message: String(
                localized: "cli.rpcBatch.error.globalOptions",
                defaultValue: "rpc-batch does not accept --window or --id-format; put explicit targets in each request's params"
            ), exitCode: 2)
        }
        var source: String?
        var dryRun = false
        var continueOnError = false
        for argument in commandArgs {
            switch argument {
            case "--dry-run": dryRun = true
            case "--continue-on-error": continueOnError = true
            default:
                guard source == nil, argument == "-" || !argument.hasPrefix("-") else {
                    throw CLIError(message: Self.rpcBatchUsage(), exitCode: 2)
                }
                source = argument
            }
        }
        guard let source else { throw CLIError(message: Self.rpcBatchUsage(), exitCode: 2) }
        let handle: FileHandle
        let closesHandle: Bool
        do {
            if source == "-" {
                handle = .standardInput
                closesHandle = false
            } else {
                let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                handle = try FileHandle(forReadingFrom: url)
                closesHandle = true
            }
        } catch {
            throw CLIError(message: String(
                localized: "cli.rpcBatch.error.read",
                defaultValue: "Could not read the RPC batch; use a readable regular file or - for standard input"
            ), exitCode: 2)
        }
        defer { if closesHandle { try? handle.close() } }
        do {
            var data = Data()
            while data.count <= CmuxRPCBatchPlan.maximumInputBytes {
                let remaining = CmuxRPCBatchPlan.maximumInputBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            let plan = try CmuxRPCBatchPlan(data: data)
            return (plan, continueOnError, dryRun)
        } catch let error as CmuxRPCBatchError {
            let format = String(
                localized: "cli.rpcBatch.error.invalid",
                defaultValue: "Invalid RPC batch (%1$@, request index %2$@). Run cmux rpc-batch --help for the input contract."
            )
            throw CLIError(message: String.localizedStringWithFormat(
                format, error.code.rawValue, error.index.map(String.init) ?? "-"
            ), exitCode: 2)
        } catch {
            throw CLIError(message: String(
                localized: "cli.rpcBatch.error.read",
                defaultValue: "Could not read the RPC batch; use a readable regular file or - for standard input"
            ), exitCode: 2)
        }
    }

    func runRPCBatch(plan: CmuxRPCBatchPlan, continueOnError: Bool, client: SocketClient) throws {
        let report = plan.execute(
            continueOnError: continueOnError,
            now: { ProcessInfo.processInfo.systemUptime }
        ) { method, params in
            do { return try client.sendV2(method: method, params: params) }
            catch let error as CLIError {
                throw CmuxRPCBatchCallFailure(
                    code: error.v2Code ?? "transport_error",
                    message: error.message,
                    canContinue: error.isStructuredProtocolResponse
                )
            }
        }
        print(jsonString(report.jsonObject))
        if !report.ok {
            throw CLIError(message: String(
                localized: "cli.rpcBatch.error.failed",
                defaultValue: "RPC batch did not complete successfully; inspect the JSON results before retrying any request"
            ))
        }
    }

    static func rpcBatchUsage() -> String {
        String(localized: "cli.rpcBatch.help", defaultValue: """
        Usage: cmux rpc-batch <file|-> [--dry-run] [--continue-on-error]

        Execute a JSON array of v2 requests in order with one CLI process.
        Local Unix sockets reuse one authenticated connection; relays retain their
        existing per-request connection behavior.
        Each request has a unique id, a method, and optional object params.
        Example: [{"id":"windows","method":"window.list"}]

        Reference an earlier result with {"$ref":"request-id#/json/pointer"}.
        Use ~0 for a literal ~ and ~1 for / in a JSON Pointer key.
        IDs use letters, digits, _ or - (1-128 bytes). References must point backward.
        Limits: 1 MiB input, 256 requests, 64 levels of JSON nesting.
        events.stream and auth.* methods cannot be batched.

        --dry-run            Validate offline and print the request count; send nothing.
        --continue-on-error  Continue independent requests after server errors or missing
                             references. Transport errors always stop the batch.

        Output is JSON with ordered results and execution timing metrics.
        Exit codes: 0 success, 1 execution/connection failure, 2 invalid input.
        Batches are sequential, not atomic. Successful requests are never rolled back
        or retried. A lost response may mean the server already applied that request.
        Put window/workspace/surface targets in params; --window and --id-format are
        not accepted. Result IDs are preserved exactly as returned by the server.
        """)
    }
}
