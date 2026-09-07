// Focused host for the production RPC batch adapter when a full app build is
// unavailable. The SocketClient below is a test transport, not cmux's transport.
// Full CLI routing, authentication, relay support, and app behavior require the
// normal built CLI integration lane. Do not ship this executable.
import CmuxFoundation
import Darwin
import Foundation

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var exitCode: Int32 = 1
    var v2Code: String? = nil
    var isStructuredProtocolResponse = false
    var description: String { message }
}

struct CMUXCLI {
    func jsonString(_ value: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}

final class SocketClient {
    private let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError(message: "socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw CLIError(message: "socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { Darwin.close(fd); throw CLIError(message: "connect failed") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    deinit { Darwin.close(fd) }

    func exchange(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw CLIError(message: "write failed") }
                offset += count
            }
        }
        var response = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 { return response }
            response.append(byte)
        }
        throw CLIError(message: "connection lost")
    }

    func sendV2(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        data.append(10)
        let raw = try exchange(data)
        guard let response = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CLIError(message: "invalid response")
        }
        if response["ok"] as? Bool == true { return response["result"] as? [String: Any] ?? [:] }
        let error = response["error"] as? [String: Any] ?? [:]
        throw CLIError(message: error["message"] as? String ?? "failed", v2Code: error["code"] as? String,
                       isStructuredProtocolResponse: true)
    }
}

@main struct RPCBatchCLIHost {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let cli = CMUXCLI()
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            var socketPath = "/tmp/cmux-rpc-batch-missing.sock"
            var window: String?
            var idFormat: String?
            while let first = args.first, first.hasPrefix("--") {
                args.removeFirst()
                if first == "--json" { continue }
                guard !args.isEmpty else { throw CLIError(message: "missing value", exitCode: 2) }
                let value = args.removeFirst()
                switch first {
                case "--socket": socketPath = value
                case "--window": window = value
                case "--id-format": idFormat = value
                default: throw CLIError(message: "unsupported harness flag", exitCode: 2)
                }
            }
            guard !args.isEmpty else { throw CLIError(message: "missing command", exitCode: 2) }
            let command = args.removeFirst()
            if args.contains("--help") {
                print(CMUXCLI.rpcBatchUsage())
                return
            }
            let parsed = try CmuxCLIArgumentParser().parse(args)
            args = parsed.remaining
            if let format = parsed.idFormat { idFormat = format }
            if command == "rpc" {
                let client = try SocketClient(path: socketPath)
                let params = args.count > 1
                    ? try JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any] ?? [:] : [:]
                print(cli.jsonString(try client.sendV2(method: args[0], params: params)))
                return
            }
            guard command == "rpc-batch" else { throw CLIError(message: "unsupported harness command", exitCode: 2) }
            let batch = try cli.prepareRPCBatch(commandArgs: args, windowID: window, idFormat: idFormat)
            if batch.dryRun {
                print(cli.jsonString(["ok": true, "dry_run": true, "requests": batch.plan.requests.count]))
                return
            }
            try cli.runRPCBatch(plan: batch.plan, continueOnError: batch.continueOnError,
                                client: SocketClient(path: socketPath))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit((error as? CLIError)?.exitCode ?? 1)
        }
    }
}
