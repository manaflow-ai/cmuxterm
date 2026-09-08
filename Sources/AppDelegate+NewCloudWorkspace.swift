import AppKit
import Foundation

// MARK: - New Cloud Workspace (Cmd+Y)

extension AppDelegate {
    /// The one path every "New Cloud Workspace" entrypoint goes through:
    /// the `newCloudWorkspace` shortcut, File > New Cloud Workspace, the
    /// plus-menu row, the `cmux.newCloudWorkspace` config action, and the
    /// command palette's "New Cloud Machine…". Gates on the Cloud Machines
    /// feature and on sign-in, then opens the New Machine sheet; Create
    /// launches `cmux vm new …`, which provisions a machine and attaches it
    /// as a new workspace.
    ///
    /// Returns false when the feature is off or the person is signed out
    /// (the sign-in workspace opens instead), so callers can beep or skip
    /// `onExecuted`.
    @discardableResult
    func performNewCloudWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace"
    ) -> Bool {
        guard CloudMachinesFeature.isEnabled else {
#if DEBUG
            cmuxDebugLog("newCloudWorkspace.blocked_feature_disabled source=\(debugSource)")
#endif
            NSSound.beep()
            return false
        }
        let authState = Self.newCloudWorkspaceAuthStateOverride ?? CloudVMPanelAuthState.resolve(
            isAuthenticated: auth?.accountFlow.isAuthenticated == true,
            isWorkingOnAuth: auth?.accountFlow.isWorkingOnAuth == true
        )
        guard authState.allowsAuthenticatedOperation else {
#if DEBUG
            cmuxDebugLog("newCloudWorkspace.blocked_signed_out source=\(debugSource)")
#endif
            _ = performAccountSignInWorkspaceAction(
                preferredWindow: preferredWindow,
                debugSource: "\(debugSource).auth"
            )
            return false
        }
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? event.flatMap { mainWindowContext(forShortcutEvent: $0, debugSource: debugSource) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        let hostWindow = context.flatMap { resolvedWindow(for: $0) }
            ?? preferredWindow
            ?? event?.window
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
#if DEBUG
        cmuxDebugLog("newCloudWorkspace.present_sheet source=\(debugSource)")
#endif
        newCloudWorkspaceSheetPresenter.presentNewMachineFetchingPlan(preferredWindow: hostWindow)
        return true
    }

    /// Test seam: the sheet presenter the shared action hands off to.
    var newCloudWorkspaceSheetPresenter: NewMachineSheetPresenting {
        Self.newCloudWorkspaceSheetPresenterOverride ?? NewMachineSheetPresenter.shared
    }

    /// Tests install a recording presenter here; nil means the real sheet.
    @MainActor
    static var newCloudWorkspaceSheetPresenterOverride: NewMachineSheetPresenting?

    /// Tests pin the sign-in state here; nil reads the live account flow.
    @MainActor
    static var newCloudWorkspaceAuthStateOverride: CloudVMPanelAuthState?
}

// MARK: - One create path for every flow

extension AppDelegate {
    /// Runs the launcher that every placeholder-filling create uses; tests
    /// swap it for a recorder.
    typealias CloudMachineCreateLaunch = @MainActor (
        _ workspace: Workspace,
        _ arguments: [String],
        _ progress: @escaping @MainActor (String) -> Void,
        _ cancellationReady: @escaping @MainActor (CloudVMActionLauncher.CancellationHandle) -> Void,
        _ completion: @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> Bool

    @MainActor
    static var cloudMachineCreateLaunchOverride: CloudMachineCreateLaunch?

    /// Starts a machine create (`vm new`, `vm fork`) the way the person
    /// experiences it: a workspace with a loading pane appears at once, the
    /// Machines panel gets a pending row, and the CLI fills the pane in when
    /// the machine is reachable. Cancel from the row closes the workspace;
    /// a failure shows in the pane with Retry, and a machine that was minted
    /// but could not be opened points at the Machines panel instead of
    /// minting a second one.
    ///
    /// Returns false when nothing could start (no window, launcher refused);
    /// the placeholder is taken down again in that case.
    @discardableResult
    func startCloudMachineCreate(
        _ request: MachineCreateRequest,
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator = .shared,
        debugSource: String = "cloudVM.create"
    ) -> Bool {
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context else {
            NSSound.beep()
            return false
        }
        let tabManager = context.tabManager
        guard let workspace = makeCloudVMPlaceholderWorkspace(
            in: tabManager,
            title: request.displayName,
            flow: request.loadingFlow,
            pinned: request.isBaseSetup
        ) else { return false }
        let boundRequest = request.withPlaceholder(workspaceID: workspace.id)
        let launchWindow = resolvedWindow(for: context) ?? preferredWindow
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let launch: CloudMachineCreateLaunch = Self.cloudMachineCreateLaunchOverride ?? { [weak self] workspace, arguments, progress, cancellationReady, completion in
            guard let self else { return false }
            return self.launchCloudVMIntoLoadingWorkspace(
                workspace: workspace,
                socketPath: socketPath,
                preferredWindow: launchWindow,
                arguments: arguments,
                onProgress: progress,
                onCancellationReady: cancellationReady,
                onCompletion: completion
            )
        }
        let workspaceID = workspace.id
        let didStart = coordinator.start(boundRequest, cancellableLaunch: { [weak workspace] arguments, progress, completion in
            guard let workspace else { return nil }
            var cancellation: CloudVMActionLauncher.CancellationHandle?
            let didLaunch = launch(workspace, arguments, progress, { cancellation = $0 }, { [weak self] result in
                if !result.succeeded, !result.wasCancelled,
                   let panel = self?.cloudVMLoadingPanel(in: workspace) {
                    let machineID = result.machineId
                        ?? MachineCreateCoordinator.createdMachineID(fromOutput: result.output)
                    if !boundRequest.isBaseSetup, machineID != nil {
                        // The machine exists; a retry would mint another.
                        panel.canRetry = false
                        panel.retryHandler = nil
                        panel.showFailure(String(
                            localized: "panel.cloudVM.loading.failed.createdOpenFailed",
                            defaultValue: "The machine was created but could not be opened here. Open it from the Machines panel."
                        ))
                    }
                }
                completion(result)
            })
            return didLaunch ? cancellation : nil
        })
        guard didStart else {
            tabManager.closeWorkspace(workspace, recordHistory: false)
            return false
        }
        if let panel = cloudVMLoadingPanel(in: workspace) {
            panel.retryHandler = { [weak coordinator] in
                guard let coordinator,
                      let operation = coordinator.operations.first(where: {
                          $0.request.placeholderWorkspaceID == workspaceID
                      }) else { return }
                _ = coordinator.retry(operation.id)
            }
        }
#if DEBUG
        cmuxDebugLog("cloudVM.create.started source=\(debugSource) workspace=\(workspaceID.uuidString) args=\(boundRequest.arguments.joined(separator: " "))")
#endif
        return true
    }
}

/// The slice of `NewMachineSheetPresenter` the New Cloud Workspace action
/// depends on, so tests can observe the handoff without a window.
@MainActor
protocol NewMachineSheetPresenting: AnyObject {
    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?)
}

extension NewMachineSheetPresenter: NewMachineSheetPresenting {}
