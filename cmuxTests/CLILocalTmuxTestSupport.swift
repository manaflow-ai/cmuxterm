import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Minimal error value needed by the pure local-tmux helpers compiled into
/// this app-hosted test bundle.
///
/// The production helpers live in the standalone `cmux-cli` executable target,
/// which cannot be imported by the app-hosted `cmuxTests` bundle. Keeping this
/// test-only shape lets the tests exercise the same helper implementations
/// without linking the executable module or duplicating the full CLI entrypoint.
struct CLIError: Error, CustomStringConvertible {
    let message: String
    let exitCode: Int32

    init(message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    var description: String { message }
}

extension CLINotifyProcessIntegrationRegressionTests {
    func testLocalTmuxAliasRejectsNonAttachActions() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["tmux", "list"],
            environment: environment,
            timeout: 10
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("only supports attach"), result.stderr)
    }
}
