import Foundation

/// Frames SSE at byte boundaries, retaining at most one bounded event.
struct ReadAloudSSEParser: Sendable {
    private let maximumFrameBytes: Int
    private var frameBytes = 0
    private var line: [UInt8] = []
    private var data = Data()
    private var hasData = false
    private var skipLF = false
    private var isFirstLine = true

    init(maximumFrameBytes: Int = 2 * 1_024 * 1_024) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func consume(_ byte: UInt8) throws -> Data? {
        if skipLF {
            skipLF = false
            if byte == 0x0A { return nil }
        }
        frameBytes += 1
        guard frameBytes <= maximumFrameBytes else {
            throw ReadAloudTransportError.responseTooLarge
        }
        if byte == 0x0D || byte == 0x0A {
            skipLF = byte == 0x0D
            return try finishLine()
        }
        line.append(byte)
        return nil
    }

    func finish() throws {
        // SSE dispatch requires a blank line. Never accept a cut-off JSON event.
        guard line.isEmpty, !hasData else {
            throw ReadAloudTransportError.truncatedStream
        }
    }

    private mutating func finishLine() throws -> Data? {
        defer { line.removeAll(keepingCapacity: true) }
        if isFirstLine {
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        guard String(bytes: line, encoding: .utf8) != nil else {
            throw ReadAloudTransportError.invalidResponse
        }
        if line.isEmpty {
            frameBytes = 0
            guard hasData else { return nil }
            let event = data
            data = Data()
            hasData = false
            return event
        }
        guard line.first != 0x3A else { return nil }
        let colon = line.firstIndex(of: 0x3A) ?? line.endIndex
        guard line[..<colon].elementsEqual([0x64, 0x61, 0x74, 0x61]) else {
            return nil
        }
        var valueStart = colon == line.endIndex ? colon : colon + 1
        if valueStart < line.endIndex, line[valueStart] == 0x20 { valueStart += 1 }
        if hasData { data.append(0x0A) }
        data.append(contentsOf: line[valueStart...])
        hasData = true
        return nil
    }
}
