import AppKit
import CmuxWindowing

/// Repairs main-window geometry after AppKit or the display system changes it.
/// The presentation mode chooses whether a window belongs in a visible frame or
/// a full display frame, so display changes and activation use the same policy.
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
            window.setFrame(targetFrame, display: true)
        }
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) " +
            "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
