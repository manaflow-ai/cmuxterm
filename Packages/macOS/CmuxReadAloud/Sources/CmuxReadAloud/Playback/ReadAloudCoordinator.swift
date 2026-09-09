import Foundation
import Observation

/// Owns one selected-text speech operation, including loading, streaming, and playback.
///
/// Route every Read Aloud and Stop action through the same coordinator. Replacing
/// a read cancels its caller immediately and prevents late audio from that read.
///
/// ```swift
/// let coordinator = ReadAloudCoordinator(
///     synthesizer: synthesizer, preferences: preferences, player: PCMReadAloudPlayer()
/// )
/// try await coordinator.read(selectedText)
/// ```
@MainActor
@Observable
public final class ReadAloudCoordinator {
    /// Whether the current read is loading, synthesizing, or still playing queued audio.
    public private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer: any ReadAloudSynthesizing
    @ObservationIgnored private let player: PCMReadAloudPlayer
    @ObservationIgnored private let authorization: @Sendable () async throws -> (ReadAloudConfiguration, String)
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var completion: CheckedContinuation<Void, any Error>?

    /// Creates the shared speech coordinator using explicit service dependencies.
    /// - Parameters:
    ///   - synthesizer: The streaming speech provider, honoring sink backpressure and cancellation.
    ///   - preferences: The configuration, consent, and Keychain credential repository.
    ///   - player: The local PCM output owned exclusively by this coordinator.
    public init(
        synthesizer: any ReadAloudSynthesizing,
        preferences: ReadAloudPreferences,
        player: PCMReadAloudPlayer
    ) {
        self.synthesizer = synthesizer
        self.player = player
        self.authorization = {
            guard await preferences.consentGranted() else {
                throw ReadAloudCoordinatorError.configurationRequired
            }
            try Task.checkCancellation()
            guard let key = try await preferences.apiKey(),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReadAloudCoordinatorError.configurationRequired
            }
            try Task.checkCancellation()
            let configuration = await preferences.configuration()
            try Task.checkCancellation()
            return (configuration, key)
        }
    }

    /// Injects authorization suspension points for isolated cancellation tests without Keychain access.
    init(
        synthesizer: any ReadAloudSynthesizing,
        player: PCMReadAloudPlayer,
        authorization: @escaping @Sendable () async throws -> (ReadAloudConfiguration, String)
    ) {
        self.synthesizer = synthesizer
        self.player = player
        self.authorization = authorization
    }

    /// Replaces any active read and waits until all generated audio has played.
    ///
    /// Empty or whitespace-only text cancels an older read without contacting the
    /// provider. Cancelling the calling task has the same effect as ``stop()``.
    /// - Parameter text: The selected text, passed to the provider without truncation.
    /// - Throws: ``ReadAloudCoordinatorError/configurationRequired`` when credentials
    ///   or consent are absent; `CancellationError` on stop, replacement, or caller
    ///   cancellation; otherwise the provider or local playback error.
    public func read(_ text: String) async throws {
        try Task.checkCancellation()
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = UUID()
        self.generation = generation
        isSpeaking = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                completion = continuation
                if Task.isCancelled {
                    stop(generation: generation)
                    return
                }
                operation = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.performRead(text, generation: generation)
                        self.complete(generation: generation, result: .success(()))
                    } catch {
                        let error = Task.isCancelled ? CancellationError() : error
                        self.complete(generation: generation, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop(generation: generation)
            }
        }
        try Task.checkCancellation()
    }

    /// Immediately cancels loading, network synthesis, and all queued audio.
    ///
    /// Pending read and playback waits resume with `CancellationError`. This does
    /// not depend on whether terminal text remains selected.
    public func stop() {
        generation = nil
        operation?.cancel()
        operation = nil
        player.stop()
        isSpeaking = false
        let completion = self.completion
        self.completion = nil
        completion?.resume(throwing: CancellationError())
    }

    private func performRead(_ text: String, generation: UUID) async throws {
        try checkActive(generation)
        let (configuration, key) = try await authorization()
        try checkActive(generation)
        player.begin(generation: generation) { [weak self] error in
            guard let self, self.generation == generation else { return }
            self.operation?.cancel()
            self.complete(generation: generation, result: .failure(error))
        }
        let player = self.player
        try await synthesizer.synthesize(text: text, configuration: configuration, apiKey: key) { data in
            try await player.append(data, generation: generation)
        }
        try checkActive(generation)
        try await player.finish(generation: generation)
        try checkActive(generation)
    }

    private func checkActive(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func stop(generation: UUID) {
        guard self.generation == generation else { return }
        stop()
    }

    private func complete(generation: UUID, result: Result<Void, any Error>) {
        guard self.generation == generation else { return }
        self.generation = nil
        operation = nil
        player.stop()
        isSpeaking = false
        let completion = self.completion
        self.completion = nil
        completion?.resume(with: result)
    }
}
