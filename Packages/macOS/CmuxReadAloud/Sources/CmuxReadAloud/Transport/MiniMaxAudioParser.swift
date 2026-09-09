import Foundation

/// Validates provider events and emits only non-aggregated, sample-aligned PCM.
struct MiniMaxAudioParser: Sendable {
    private(set) var isComplete = false
    private var receivedAudio = false
    private var pendingSampleByte: UInt8?
    private let decoder = JSONDecoder()

    mutating func consume(_ event: Data) throws -> Data? {
        if event.isEmpty { return nil }
        if event == Data("[DONE]".utf8) {
            try finish()
            return nil
        }
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: event)
        } catch {
            throw ReadAloudTransportError.invalidResponse
        }
        if envelope.base_resp.status_code != 0 {
            throw ReadAloudTransportError.provider(code: envelope.base_resp.status_code)
        }
        if let info = envelope.extra_info {
            guard (info.audio_sample_rate == nil || info.audio_sample_rate == 32_000),
                  (info.audio_channel == nil || info.audio_channel == 1),
                  (info.audio_format == nil || info.audio_format == "pcm") else {
                throw ReadAloudTransportError.invalidResponse
            }
        }
        guard let payload = envelope.data else { return nil }
        guard !isComplete else { throw ReadAloudTransportError.invalidResponse }
        switch payload.status {
        case 1:
            guard let hex = payload.audio, !hex.isEmpty else { return nil }
            var audio = try decodeHex(hex)
            if let pendingSampleByte { audio.insert(pendingSampleByte, at: 0) }
            pendingSampleByte = nil
            if !audio.count.isMultiple(of: 2) { pendingSampleByte = audio.removeLast() }
            guard !audio.isEmpty else { return nil }
            receivedAudio = true
            return audio
        case 2:
            // The documented status-2 audio is an aggregate, not another delta.
            // Request exclusion as well, but never replay an aggregate if returned.
            if let hex = payload.audio { try validateHex(hex) }
            guard pendingSampleByte == nil else {
                throw ReadAloudTransportError.truncatedStream
            }
            isComplete = true
            return nil
        default:
            throw ReadAloudTransportError.invalidResponse
        }
    }

    func finish() throws {
        guard isComplete, pendingSampleByte == nil else {
            throw ReadAloudTransportError.truncatedStream
        }
        guard receivedAudio else { throw ReadAloudTransportError.noAudio }
    }

    private func decodeHex(_ hex: String) throws -> Data {
        guard hex.utf8.count.isMultiple(of: 2) else {
            throw ReadAloudTransportError.invalidResponse
        }
        var result = Data(capacity: hex.utf8.count / 2 + 1)
        var iterator = hex.utf8.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(), let upper = nibble(high), let lower = nibble(low) else {
                throw ReadAloudTransportError.invalidResponse
            }
            result.append((upper << 4) | lower)
        }
        return result
    }

    private func validateHex(_ hex: String) throws {
        guard hex.utf8.count.isMultiple(of: 2), hex.utf8.allSatisfy({ nibble($0) != nil }) else {
            throw ReadAloudTransportError.invalidResponse
        }
    }

    private func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private struct Envelope: Decodable {
        let data: Payload?
        let base_resp: BaseResponse
        let extra_info: AudioInfo?
    }

    private struct Payload: Decodable {
        let audio: String?
        let status: Int
    }

    private struct BaseResponse: Decodable {
        let status_code: Int
    }

    private struct AudioInfo: Decodable {
        let audio_sample_rate: Int?
        let audio_channel: Int?
        let audio_format: String?
    }
}
