import Foundation

/// Synthesizes selected text into mono 32 kHz signed 16-bit little-endian PCM.
public protocol ReadAloudSynthesizing: Sendable {
    /// Streams audio, awaiting consumption before reading the next audio chunk.
    ///
    /// The sink is a backpressure boundary, not a completion callback. Cancellation
    /// must stop the underlying request. No text, key, or audio is persisted.
    /// - Parameters:
    ///   - text: The selected text, without silent truncation.
    ///   - configuration: Model, voice, and speed preferences.
    ///   - apiKey: The caller-provided MiniMax credential.
    ///   - audioSink: Consumes a chunk before synthesis continues reading.
    /// - Throws: Cancellation, transport, provider, or consumption errors.
    func synthesize(
        text: String,
        configuration: ReadAloudConfiguration,
        apiKey: String,
        audioSink: @escaping @Sendable (Data) async throws -> Void
    ) async throws
}
