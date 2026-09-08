import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func nextTransportTicketRejectsUnexpectedArgumentsBeforeRPC() throws {
        let cli = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-ticket-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = "/tmp/cmux-next-ticket-\(UUID().uuidString.prefix(8)).sock"
        let output = root.appendingPathComponent("material.json")
        let responder = try UnixSocketResponder(path: socket, response: "{\"ticket\":\"must-not-mint\"}")
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
        environment["CMUX_SOCKET_PATH"] = socket
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cli,
            arguments: ["next-transport-ticket", "unexpected", "--output", output.path],
            environment: environment, timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status != 0, Comment(rawValue: result.diagnostics))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(responder.receivedRequests.isEmpty)
    }
}
