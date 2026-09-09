import AppKit
import CmuxTerminalCore
import GhosttyKit
@testable import CmuxTerminal

final class FakeTerminalSurfaceNativeView: NSView {
    var tabId: UUID?
    var hostedTabId: UUID? { tabId }
    weak var attachedController: (any TerminalSurfaceControlling)?
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { attachedController }
    var currentKeyStateIndicatorText: String? { nil }
    var isKeyboardCopyModeActive = false
    private(set) var keyboardCopyModeCancellationCount = 0
    var shouldDeferRuntimeInput = false
    var runtimeInputDeferralResponses: [Bool] = []
    var runtimeInputDeferralCallCount = 0
    var deferredRuntimeInputs: [() -> Void] = []
    var deferredRuntimeInputBytes: [Int] = []
    private var deferredRuntimeInputHumanFlags: [Bool] = []
    private var deferredRuntimeInputDiscards: [(() -> Void)?] = []
    var mobileMouseButtonEvents: [String] = []

    func toggleKeyboardCopyMode() -> Bool { false }
    func cancelKeyboardCopyMode() {
        keyboardCopyModeCancellationCount += 1
        isKeyboardCopyModeActive = false
    }
    func applyWindowBackgroundIfActive() {}
    func forceRefreshSurface() -> Bool { true }
    func runtimeSurfaceDidBecomeReady() {}

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool {
        enqueueDeferredRuntimeInput(
            estimatedBytes: estimatedBytes,
            isHumanInput: true,
            replay: replay,
            onDiscard: nil
        )
    }

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        isHumanInput: Bool,
        replay: @escaping () -> Void
    ) -> Bool {
        enqueueDeferredRuntimeInput(
            estimatedBytes: estimatedBytes,
            isHumanInput: isHumanInput,
            replay: replay,
            onDiscard: nil
        )
    }

    private func enqueueDeferredRuntimeInput(
        estimatedBytes: Int,
        isHumanInput: Bool,
        replay: @escaping () -> Void,
        onDiscard: (() -> Void)?
    ) -> Bool {
        runtimeInputDeferralCallCount += 1
        let shouldDefer = runtimeInputDeferralResponses.isEmpty
            ? shouldDeferRuntimeInput
            : runtimeInputDeferralResponses.removeFirst()
        guard shouldDefer else { return false }
        deferredRuntimeInputBytes.append(estimatedBytes)
        deferredRuntimeInputHumanFlags.append(isHumanInput)
        deferredRuntimeInputDiscards.append(onDiscard)
        deferredRuntimeInputs.append { [weak self] in
            self?.consumeDeferredRuntimeInput()
            replay()
        }
        return true
    }

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        isHumanInput: Bool,
        replay: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) -> Bool {
        enqueueDeferredRuntimeInput(
            estimatedBytes: estimatedBytes,
            isHumanInput: isHumanInput,
            replay: replay,
            onDiscard: onDiscard
        )
    }

    @discardableResult
    func discardNextDeferredRuntimeInput() -> Bool {
        guard !deferredRuntimeInputs.isEmpty else { return false }
        _ = deferredRuntimeInputs.removeFirst()
        if let onDiscard = consumeDeferredRuntimeInput() {
            onDiscard()
        }
        return true
    }

    @discardableResult
    private func consumeDeferredRuntimeInput() -> (() -> Void)? {
        if !deferredRuntimeInputHumanFlags.isEmpty {
            deferredRuntimeInputHumanFlags.removeFirst()
        }
        guard !deferredRuntimeInputDiscards.isEmpty else { return nil }
        return deferredRuntimeInputDiscards.removeFirst()
    }

    func hasDeferredHumanInputDuringClipboardRead() -> Bool {
        deferredRuntimeInputHumanFlags.contains(true)
    }

    func positionMobilePointer(
        on _: ghostty_surface_t,
        column _: Int,
        row _: Int,
        contentScale _: CGFloat
    ) {}

    func sendMobileMouseButton(
        _ state: ghostty_input_mouse_state_e,
        on _: ghostty_surface_t
    ) {
        mobileMouseButtonEvents.append(
            state == GHOSTTY_MOUSE_PRESS ? "press" : "release"
        )
    }
}

extension FakeTerminalSurfaceNativeView: @preconcurrency TerminalSurfaceHosting {}
extension FakeTerminalSurfaceNativeView: TerminalSurfaceNativeViewing {}
