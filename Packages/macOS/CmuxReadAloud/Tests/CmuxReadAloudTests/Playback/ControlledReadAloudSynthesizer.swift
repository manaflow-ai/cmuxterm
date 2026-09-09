import Foundation
@testable import CmuxReadAloud

/// Sends late audio only when the test releases a simulated suspended request.
actor ControlledReadAloudSynthesizer: ReadAloudSynthesizing {
    enum Outcome: Equatable, Sendable {
        case completed(String)
        case cancelled(String)
        case failed(String)
    }

    enum Failure: Error {
        case unexpectedRequest
    }

    nonisolated let outcomes: AsyncStream<Outcome>
    private let outcomeContinuation: AsyncStream<Outcome>.Continuation
    private let requests: [String: ReadAloudTestGate<Data?>]
    private(set) var requestedTexts: [String] = []

    init(requests: [String: ReadAloudTestGate<Data?>]) {
        self.requests = requests
        (outcomes, outcomeContinuation) = AsyncStream<Outcome>.makeStream()
    }

    func synthesize(
        text: String,
        configuration: ReadAloudConfiguration,
        apiKey: String,
        audioSink: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        requestedTexts.append(text)
        guard let request = requests[text] else { throw Failure.unexpectedRequest }
        let audio = await request.wait()
        do {
            if let audio {
                // Model an escaped provider callback without the cancelled task's
                // flag, so rejection must come from the playback generation fence.
                try await Task.detached { try await audioSink(audio) }.value
            }
            outcomeContinuation.yield(.completed(text))
        } catch is CancellationError {
            outcomeContinuation.yield(.cancelled(text))
            throw CancellationError()
        } catch {
            outcomeContinuation.yield(.failed(text))
            throw error
        }
    }
}
