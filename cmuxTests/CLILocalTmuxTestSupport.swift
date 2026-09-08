import Foundation

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
