import Foundation
import Testing
@testable import CmuxReadAloud

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ReadAloudCoordinatorTests {
    enum CancellationMethod: Sendable {
        case stop
        case cancelCaller
    }

    @Test(arguments: [CancellationMethod.stop, .cancelCaller])
    func cancellationReleasesCallerBeforeAuthorizationReturns(_ method: CancellationMethod) async {
        let authorization = ReadAloudTestGate<Void>()
        let synthesizer = ControlledReadAloudSynthesizer(requests: [:])
        let coordinator = ReadAloudCoordinator(synthesizer: synthesizer, player: PCMReadAloudPlayer()) {
            await authorization.wait()
            return (ReadAloudConfiguration(), "test-only-key")
        }
        let read = Task { try await coordinator.read("selected text") }
        await authorization.waitUntilEntered()
        #expect(coordinator.isSpeaking)
        switch method {
        case .stop: coordinator.stop()
        case .cancelCaller: read.cancel()
        }
        // This must finish while authorization is still suspended, not after its release.
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(!coordinator.isSpeaking)
        #expect(await synthesizer.requestedTexts.isEmpty)
        await authorization.release(())
    }

    @Test
    func replacementRejectsLateAudioWithoutStoppingNewRead() async throws {
        let first = ReadAloudTestGate<Data?>()
        let second = ReadAloudTestGate<Data?>()
        let synthesizer = ControlledReadAloudSynthesizer(requests: ["first": first, "second": second])
        var outcomes = synthesizer.outcomes.makeAsyncIterator()
        let coordinator = ReadAloudCoordinator(synthesizer: synthesizer, player: PCMReadAloudPlayer()) {
            (ReadAloudConfiguration(), "test-only-key")
        }
        let oldRead = Task { try await coordinator.read("first") }
        await first.waitUntilEntered()
        let newRead = Task { try await coordinator.read("second") }
        await second.waitUntilEntered()
        await #expect(throws: CancellationError.self) { try await oldRead.value }
        // One byte never opens audio hardware, but an unfenced sink would retain
        // it as a partial sample and incorrectly report successful consumption.
        await first.release(Data([0x7f]))
        #expect(await outcomes.next() == .cancelled("first"))
        #expect(coordinator.isSpeaking)
        await second.release(nil)
        try await newRead.value
        #expect(!coordinator.isSpeaking)
    }

    @Test
    func emptySelectionStopsExistingReadWithoutAnotherRequest() async throws {
        let first = ReadAloudTestGate<Data?>()
        let synthesizer = ControlledReadAloudSynthesizer(requests: ["first": first])
        let coordinator = ReadAloudCoordinator(synthesizer: synthesizer, player: PCMReadAloudPlayer()) {
            (ReadAloudConfiguration(), "test-only-key")
        }
        let oldRead = Task { try await coordinator.read("first") }
        await first.waitUntilEntered()
        try await coordinator.read(" \n\t")
        await #expect(throws: CancellationError.self) { try await oldRead.value }
        #expect(!coordinator.isSpeaking)
        #expect(await synthesizer.requestedTexts == ["first"])
        await first.release(nil)
    }

    @Test
    func alreadyCancelledCallerCannotInterruptActiveRead() async throws {
        let active = ReadAloudTestGate<Data?>()
        let delayedStart = ReadAloudTestGate<Void>()
        let synthesizer = ControlledReadAloudSynthesizer(requests: ["active": active])
        let coordinator = ReadAloudCoordinator(synthesizer: synthesizer, player: PCMReadAloudPlayer()) {
            (ReadAloudConfiguration(), "test-only-key")
        }
        let activeRead = Task { try await coordinator.read("active") }
        await active.waitUntilEntered()
        let cancelledRead = Task {
            await delayedStart.wait()
            try await coordinator.read("cancelled")
        }
        await delayedStart.waitUntilEntered()
        cancelledRead.cancel()
        await delayedStart.release(())
        await #expect(throws: CancellationError.self) { try await cancelledRead.value }
        #expect(coordinator.isSpeaking)
        #expect(await synthesizer.requestedTexts == ["active"])
        await active.release(nil)
        try await activeRead.value
    }
}
