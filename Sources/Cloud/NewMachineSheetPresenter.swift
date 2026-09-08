import AppKit
import SwiftUI

/// Shows one ``NewMachineSheet`` at a time as a window sheet on the main cmux
/// window (floating panel when no main window is on screen) and closes it
/// when the model finishes. The sheet only collects the choice: Create hands
/// the request to ``MachineCreateCoordinator`` and the sheet ends at once, so
/// the window is modal for exactly as long as the person is choosing.
@MainActor
final class NewMachineSheetPresenter {
    static let shared = NewMachineSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: NewMachineModel?

    private init() {}

    var isPresenting: Bool { sheetWindow != nil }

    /// Presents the sheet. A second request while one is up just re-raises the
    /// host window so the open sheet is where the person looks.
    func present(model: NewMachineModel, preferredWindow: NSWindow?) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: NewMachineSheet(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = model.isBaseSetup
            ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.title", defaultValue: "New Machine")
        window.isReleasedWhenClosed = false
        let previousOnFinished = model.onFinished
        model.onFinished = { [weak self] outcome in
            previousOnFinished?(outcome)
            self?.dismiss()
        }
        self.model = model
        sheetWindow = window

        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { _ in }
        } else {
            // No host: float it. Cancel is the only way out, so no close button
            // can leave the presenter holding a window nobody sees.
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The one path every "New Machine" entrypoint (Machines panel ＋, the
    /// command palette) goes through: paywall check, model, sheet. Create
    /// launches `cmux vm new …` through the shared coordinator; the Machines
    /// panel shows the pending row and the outcome, whichever window it is in.
    /// `plan` and `memoryOptionsMb` come from whatever fleet page the caller
    /// already holds.
    func presentNewMachine(
        plan: MachinePlanSnapshot?,
        memoryOptionsMb: [Int],
        sourceMachines: [NewMachineModel.SourceMachine] = [],
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator? = nil
    ) {
        let coordinator = coordinator ?? .shared
        if let plan, plan.isAtLimit, !plan.isPaidPlan {
            ProUpgradePresenter.present()
            return
        }
        let model = NewMachineModel(
            mode: .newMachine,
            plan: plan,
            memoryOptionsMb: memoryOptionsMb,
            sourceOptions: sourceMachines,
            submit: { request in
                // Create makes the workspace at once: a loading pane shows the
                // machine coming up and the CLI fills that pane in when the
                // machine is reachable. No AppDelegate (tests) falls back to
                // the bare background launch without a placeholder.
                guard let appDelegate = AppDelegate.shared else {
                    return coordinator.start(request, cancellableLaunch: { arguments, progress, completion in
                        var cancellation: CloudVMActionLauncher.CancellationHandle?
                        let didStart = MachineRowActions.openNewMachine(
                            arguments: arguments,
                            onOutput: progress,
                            onCompletion: completion,
                            onCancellationReady: { cancellation = $0 }
                        )
                        return didStart ? cancellation : nil
                    })
                }
                return appDelegate.startCloudMachineCreate(
                    request,
                    preferredWindow: preferredWindow,
                    coordinator: coordinator
                )
            }
        )
        present(model: model, preferredWindow: preferredWindow)
    }

    /// The fleet rows a New Machine sheet offers as fork sources: every
    /// machine that is provisioned (running, paused, or asleep). Machines
    /// still coming up or in trouble cannot be snapshotted.
    nonisolated static func sourceMachines(from vms: [VMSummary]) -> [NewMachineModel.SourceMachine] {
        vms.compactMap { vm in
            guard MachineSnapshotBuilder.activity(fromStatus: vm.status) == .ready else { return nil }
            return NewMachineModel.SourceMachine(id: vm.id, name: vm.preferredName)
        }
    }

    /// Entrypoints with no panel state on hand (command palette) read the
    /// fleet page first for the plan meter and image kinds. A nil page (signed
    /// out, unreachable) still opens the sheet; the CLI reports the real error
    /// through the Machines panel when the person creates.
    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?) {
        Task { @MainActor in
            var page: VMListPage?
            if let client = VMClient.shared {
                page = try? await client.listPage()
            }
            presentNewMachine(
                plan: MachineSnapshotBuilder.planSnapshot(activeCount: page?.vms.count ?? 0, limits: page?.limits),
                memoryOptionsMb: page?.limits?.memoryOptionsMb ?? [],
                sourceMachines: Self.sourceMachines(from: page?.vms ?? []),
                preferredWindow: preferredWindow
            )
        }
    }

    private func dismiss() {
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
        model = nil
    }
}
