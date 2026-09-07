import Foundation

extension CMUXCLI {
    /// The small set of root fields needed to conclude an oversized Cursor
    /// post-tool hook without retaining its untrusted result body.
    struct CursorNativeApprovalOversizedMetadata: Sendable {
        let sessionId: String
        let toolCallId: String
        let generationId: String?
        let command: String?
    }

    /// Incrementally scans a bounded JSON root object while discarding large
    /// values. Cursor may put `tool_output` before its correlation IDs, so a
    /// fixed prefix is insufficient; this scanner keeps only short requested
    /// scalar fields and never buffers an untrusted result string.
    struct CursorNativeApprovalRootFieldScanner {
        static let maximumScanBytes = 4 * 1024 * 1024

        private enum Phase {
            case seekingRoot
            case expectingKeyOrEnd
            case readingKey
            case expectingColon
            case expectingValue
            case readingValue
            case skippingString
            case skippingComposite
            case skippingScalar
            case afterValue
            case finished
            case invalid
        }

        private enum Field {
            case session
            case toolCall
            case generation
            case command
        }

        private var phase: Phase = .seekingRoot
        private var keyBytes: [UInt8] = []
        private var valueBytes: [UInt8] = []
        private var keyOverflowed = false
        private var valueOverflowed = false
        private var pendingKey: Field?
        private var escaped = false
        private var compositeDepth = 0
        private var compositeInString = false
        private var compositeEscaped = false
        private var sessionId: String?
        private var toolCallId: String?
        private var generationId: String?
        private var command: String?

        /// The metadata is available once both required correlation fields
        /// have been seen at the root level.
        var metadata: CursorNativeApprovalOversizedMetadata? {
            guard let sessionId, let toolCallId else { return nil }
            return CursorNativeApprovalOversizedMetadata(
                sessionId: sessionId,
                toolCallId: toolCallId,
                generationId: generationId,
                command: command
            )
        }

        var hasRequiredIdentifiers: Bool {
            sessionId != nil && toolCallId != nil
        }

        mutating func consume(_ data: Data) {
            guard phase != .finished, phase != .invalid else { return }
            for byte in data {
                consume(byte)
                if phase == .finished || phase == .invalid {
                    return
                }
            }
        }

        private mutating func consume(_ byte: UInt8) {
            switch phase {
            case .seekingRoot:
                guard isWhitespace(byte) else {
                    guard byte == 0x7B else {
                        phase = .invalid
                        return
                    }
                    phase = .expectingKeyOrEnd
                    return
                }
            case .expectingKeyOrEnd:
                if isWhitespace(byte) || byte == 0x2C { return }
                if byte == 0x7D {
                    phase = .finished
                } else if byte == 0x22 {
                    keyBytes.removeAll(keepingCapacity: true)
                    keyOverflowed = false
                    escaped = false
                    phase = .readingKey
                } else {
                    phase = .invalid
                }
            case .readingKey:
                guard consumeKeyByte(byte) else { return }
                pendingKey = keyOverflowed
                    ? nil
                    : Self.field(for: Self.decodeString(keyBytes))
                phase = .expectingColon
            case .expectingColon:
                if isWhitespace(byte) { return }
                guard byte == 0x3A else {
                    phase = .invalid
                    return
                }
                phase = .expectingValue
            case .expectingValue:
                if isWhitespace(byte) { return }
                if byte == 0x22 {
                    valueBytes.removeAll(keepingCapacity: true)
                    valueOverflowed = false
                    escaped = false
                    phase = pendingKey == nil ? .skippingString : .readingValue
                } else if byte == 0x7B || byte == 0x5B {
                    compositeDepth = 1
                    compositeInString = false
                    compositeEscaped = false
                    phase = .skippingComposite
                } else if byte == 0x2C {
                    phase = .invalid
                } else if byte == 0x7D {
                    phase = .invalid
                } else {
                    phase = .skippingScalar
                }
            case .readingValue:
                guard consumeValueByte(byte) else { return }
                if !valueOverflowed,
                   let value = Self.decodeString(valueBytes),
                   let field = pendingKey {
                    record(value: value, for: field)
                }
                pendingKey = nil
                phase = .afterValue
            case .skippingString:
                if consumeDiscardedStringByte(byte) {
                    pendingKey = nil
                    phase = .afterValue
                }
            case .skippingComposite:
                consumeCompositeByte(byte)
            case .skippingScalar:
                if byte == 0x2C {
                    pendingKey = nil
                    phase = .expectingKeyOrEnd
                } else if byte == 0x7D {
                    phase = .finished
                }
            case .afterValue:
                if isWhitespace(byte) { return }
                if byte == 0x2C {
                    phase = .expectingKeyOrEnd
                } else if byte == 0x7D {
                    phase = .finished
                } else {
                    phase = .invalid
                }
            case .finished, .invalid:
                return
            }
        }

        private mutating func consumeKeyByte(_ byte: UInt8) -> Bool {
            if escaped {
                append(byte, to: &keyBytes, overflowed: &keyOverflowed, maximumBytes: 128)
                escaped = false
                return false
            }
            if byte == 0x5C {
                append(byte, to: &keyBytes, overflowed: &keyOverflowed, maximumBytes: 128)
                escaped = true
                return false
            }
            if byte == 0x22 {
                return true
            }
            append(byte, to: &keyBytes, overflowed: &keyOverflowed, maximumBytes: 128)
            return false
        }

        private mutating func consumeValueByte(_ byte: UInt8) -> Bool {
            if escaped {
                append(
                    byte,
                    to: &valueBytes,
                    overflowed: &valueOverflowed,
                    maximumBytes: 4_096
                )
                escaped = false
                return false
            }
            if byte == 0x5C {
                append(
                    byte,
                    to: &valueBytes,
                    overflowed: &valueOverflowed,
                    maximumBytes: 4_096
                )
                escaped = true
                return false
            }
            if byte == 0x22 { return true }
            append(
                byte,
                to: &valueBytes,
                overflowed: &valueOverflowed,
                maximumBytes: 4_096
            )
            return false
        }

        private mutating func consumeDiscardedStringByte(_ byte: UInt8) -> Bool {
            if escaped {
                escaped = false
                return false
            }
            if byte == 0x5C {
                escaped = true
                return false
            }
            return byte == 0x22
        }

        private mutating func consumeCompositeByte(_ byte: UInt8) {
            if compositeInString {
                if compositeEscaped {
                    compositeEscaped = false
                } else if byte == 0x5C {
                    compositeEscaped = true
                } else if byte == 0x22 {
                    compositeInString = false
                }
                return
            }
            switch byte {
            case 0x22:
                compositeInString = true
            case 0x7B, 0x5B:
                compositeDepth += 1
            case 0x7D, 0x5D:
                compositeDepth -= 1
                if compositeDepth <= 0 {
                    pendingKey = nil
                    phase = .afterValue
                }
            default:
                break
            }
        }

        private mutating func append(
            _ byte: UInt8,
            to buffer: inout [UInt8],
            overflowed: inout Bool,
            maximumBytes: Int
        ) {
            guard !overflowed else { return }
            guard buffer.count < maximumBytes else {
                overflowed = true
                return
            }
            buffer.append(byte)
        }

        private mutating func record(value: String, for field: Field) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch field {
            case .session where sessionId == nil:
                sessionId = value
            case .toolCall where toolCallId == nil:
                toolCallId = value
            case .generation where generationId == nil:
                generationId = value
            case .command where command == nil:
                command = value
            default:
                break
            }
        }

        private static func field(for key: String?) -> Field? {
            switch key {
            case "session_id", "sessionId", "conversation_id", "conversationId":
                return .session
            case "tool_call_id", "toolCallId", "tool_use_id", "toolUseId", "toolUseID":
                return .toolCall
            case "generation_id", "generationId", "turn_id", "turnId":
                return .generation
            case "command", "shell_command", "shellCommand":
                return .command
            default:
                return nil
            }
        }

        private static func decodeString(_ bytes: [UInt8]) -> String? {
            var wrapped = Data([0x22])
            wrapped.append(contentsOf: bytes)
            wrapped.append(0x22)
            return (try? JSONSerialization.jsonObject(with: wrapped)) as? String
        }

        private func isWhitespace(_ byte: UInt8) -> Bool {
            [0x20, 0x09, 0x0A, 0x0D].contains(byte)
        }
    }

    /// Concludes Cursor attention from the bounded lifecycle projection at
    /// the front of an oversized post-tool payload. The unbounded result body
    /// remains excluded from JSON decoding and Feed transport.
    func concludeCursorNativeApprovalObservation(
        metadata: CursorNativeApprovalOversizedMetadata,
        agentPID: Int,
        socketPath: String?,
        socketPassword: String?
    ) {
        var rawObject: [String: Any] = [
            "session_id": metadata.sessionId,
            "tool_use_id": metadata.toolCallId,
        ]
        if let generationId = metadata.generationId {
            rawObject["generation_id"] = generationId
        }
        if let command = metadata.command {
            rawObject["command"] = command
        }
        concludeCursorNativeApprovalObservation(
            rawObject: rawObject,
            agentPID: agentPID,
            sessionId: metadata.sessionId,
            socketPath: socketPath,
            socketPassword: socketPassword
        )
    }

    func concludeCursorNativeApprovalObservation(
        boundedJSONPrefix: Data,
        agentPID: Int,
        socketPath: String?,
        socketPassword: String?
    ) {
        var scanner = CursorNativeApprovalRootFieldScanner()
        scanner.consume(boundedJSONPrefix)
        guard let metadata = scanner.metadata else { return }
        concludeCursorNativeApprovalObservation(
            metadata: metadata,
            agentPID: agentPID,
            socketPath: socketPath,
            socketPassword: socketPassword
        )
    }
}
