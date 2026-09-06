import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Pointer ingress semantic preservation")
struct TerminalPointerIngressRegressionTests {
    @Test("coalescing preserves the last supported shape before an unsupported shape")
    func supportedIntermediateShapeSurvivesCoalescing() async {
        let runtimeID = UUID()
        let surfaceID = UUID()
        let view = GhosttyNSView(frame: .zero)
        let ingress = GhosttyPointerStyleIngress(surfaceView: view)
        let shapes = [GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_COPY, GHOSTTY_MOUSE_SHAPE_WAIT]
        let requests = shapes.enumerated().map { index, shape in
            GhosttyPointerStyleIngressRequest(
                event: .shape(shape), surfaceId: surfaceID, runtimeLifetimeId: runtimeID,
                sequence: UInt64(index + 1), runtimeGeneration: 1
            )
        }
        let delivered = await ingress.coalesceBatch(requests)
        var presentation = TerminalPointerStyleState()
        presentation.apply(.runtimeActivated(runtimeID))
        presentation.apply(.focusChanged(true))
        for request in delivered {
            if let event = request.event.terminalEvent(runtimeLifetimeId: runtimeID) {
                presentation.apply(event)
            }
        }
        #expect(presentation.effectiveCursor == NSCursor.dragCopy)
    }
}

extension GhosttyPointerStyleIngress {
    /// Runs the production reducer in one actor turn before a UI drain can interleave.
    fileprivate func coalesceBatch(
        _ requests: [GhosttyPointerStyleIngressRequest]
    ) async -> [GhosttyPointerStyleIngressRequest] {
        for request in requests { receive(request) }
        let pending = await takePending(afterLifecycleSequence: 0)
        return pending.values.flatMap { runtime in
            [runtime.firstShape, runtime.latestShape, runtime.latestLinkHover,
             runtime.latestRuntimeReset, runtime.latestRuntimeEnded].compactMap { $0 }
        }.sorted { $0.sequence < $1.sequence }
    }
}
