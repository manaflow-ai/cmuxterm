import AppKit
import CmuxWindowing

/// Repairs main-window geometry after AppKit or the display system changes it.
/// Display changes, activation, and restoration share one policy: recover
/// ordinary and zoomed windows while leaving fullscreen layouts to AppKit.
@MainActor
final class MainWindowFrameReconciler {
    private let fitCore: MainWindowVisibleFrameFitCore

    /// Describes the lifecycle event that requested a frame repair.
    enum Trigger {
        case displayTopology(repairOrdinaryWindows: Bool)
        case applicationActivation
        case restorationCheckpoint

        var repairsOrdinaryWindows: Bool {
            switch self {
            case .displayTopology(let repairOrdinaryWindows):
                return repairOrdinaryWindows
            case .restorationCheckpoint:
                return true
            case .applicationActivation:
                return false
            }
        }
    }

    init(fitCore: MainWindowVisibleFrameFitCore = MainWindowVisibleFrameFitCore()) {
        self.fitCore = fitCore
    }

    func repair(
        displays: [SessionDisplayGeometry],
        windows: [NSWindow],
        trigger: Trigger
    ) {
        guard !displays.isEmpty else { return }

        let mainWindows = windows.compactMap { $0 as? CmuxMainWindow }
        guard !mainWindows.isEmpty else { return }

        for window in mainWindows {
            let mode: MainWindowFrameFitMode?
            if window.styleMask.contains(.fullScreen) {
                // Split View also sets this style; the core must not replace
                // AppKit's tile with an entire display or a zoomed frame.
                mode = .nativeFullscreen
            } else if window.cmuxWantsZoomedFrame {
                mode = .zoomed
            } else if trigger.repairsOrdinaryWindows {
                mode = .visibleFrame
            } else {
                mode = nil
            }

            guard let mode,
                  let targetFrame = fitCore.repairedFrame(
                      for: window.frame,
                      displays: displays,
                      minimumWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
                      minimumHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight),
                      mode: mode
                  ) else {
                continue
            }
            guard targetFrame != window.frame else { continue }
            let originalFrame = window.frame
#if DEBUG
            cmuxDebugLog(
                "mainWindow.frameRepair.clamp win=\(window.windowNumber) " +
                    "from={\(Self.rectDescription(originalFrame))} to={\(Self.rectDescription(targetFrame))}"
            )
#endif
            sentryBreadcrumb(
                "mainWindow.frameRepair.clamp",
                category: "window",
                data: [
                    "from": Self.rectDescription(originalFrame),
                    "to": Self.rectDescription(targetFrame),
                ]
            )
            window.setFrameForManagedPlacement(targetFrame, display: true)
        }
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
