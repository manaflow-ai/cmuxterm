import Foundation

/// Locates the encoded script in current and historical CLI startup wrappers.
enum SSHStartupCommandTestSupport {
    static func payloadRange(in command: String) -> Range<String.Index>? {
        if let assignment = command.range(of: "cmux_payload=") {
            let end = command[assignment.upperBound...].firstIndex(of: "\n") ?? command.endIndex
            return unquoted(assignment.upperBound..<end, in: command)
        }
        guard let prefix = command.range(of: "(printf %s "),
              let suffix = command.range(of: " | base64", range: prefix.upperBound..<command.endIndex) else {
            return nil
        }
        return unquoted(prefix.upperBound..<suffix.lowerBound, in: command)
    }

    private static func unquoted(_ range: Range<String.Index>, in command: String) -> Range<String.Index> {
        guard !range.isEmpty else { return range }
        let last = command.index(before: range.upperBound)
        let first = command[range.lowerBound]
        if range.lowerBound != last, (first == "'" || first == "\""), command[last] == first {
            return command.index(after: range.lowerBound)..<last
        }
        return range
    }
}
