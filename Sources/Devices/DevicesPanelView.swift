import AppKit
import CmuxSettings
import Combine
import SwiftUI

/// Right-sidebar Devices tab: the account's other Macs as the same
/// Finder-like tree the Cloud tab draws for cloud machines (device → Workspaces
/// → terminals; Terminals pool), rendered by the shared `CloudTreeOutlineView`
/// with `source: .devices`. Auth-gated like the Cloud tab. Every verb routes
/// through `CloudTreeNodeActions`, so a row, a drop, the socket, and the CLI
/// share one mutation path; nothing here talks to a device directly.
struct DevicesPanelView: View {
    @State private var viewModel = DevicesPanelViewModel()
    @State private var expansionStore = CloudTreeExpansionStore()
    @AppStorage(CloudTreeStyleStore.defaultsKey) private var cloudTreeStyleID: String = CloudTreeStyle.defaultStyle.id
    let chromeBackgroundColor: NSColor

    private var accountFlow: HostAccountFlow? {
        AppDelegate.shared?.auth?.accountFlow
    }

    private var authState: CloudVMPanelAuthState {
        CloudVMPanelAuthState.resolve(
            isAuthenticated: accountFlow?.isAuthenticated == true,
            isWorkingOnAuth: accountFlow?.isCompletingSignIn == true
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            switch authState {
            case .checking:
                authCheckingState
            case .signedOut:
                authGate
            case .signedIn:
                controlBar
                content
            }
        }
        .onAppear { viewModel.start() }
        .onChange(of: authState) { _, _ in viewModel.start() }
        .onReceive(NotificationCenter.default.publisher(for: DeviceSurfaceProviderRegistry.revealDeviceNotification)) { _ in
            viewModel.consumePendingReveal()
        }
        .accessibilityIdentifier("DevicesPanel")
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            Group {
                if let operation = viewModel.activeOperation {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(operation)
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if let status = viewModel.statusText {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if viewModel.statusIsWarning {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(status)
                            .cmuxFont(size: 11)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(viewModel.statusIsWarning ? .orange.opacity(0.9) : .secondary)
                    .help(status)
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            MachinesChromeIconButton(
                symbolName: "arrow.clockwise",
                accessibilityLabel: String(localized: "devices.refresh", defaultValue: "Refresh Devices"),
                isBusy: viewModel.isRefreshing
            ) {
                viewModel.refresh()
            }
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder(backgroundColor: chromeBackgroundColor)
    }

    @ViewBuilder
    private var content: some View {
        if CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: viewModel.catalog, source: .devices) {
            emptyState
        } else {
            devicesList
        }
    }

    /// The same outline the Cloud tab uses, fed the device machines only. The
    /// cloud row verbs are bound to an inert bundle: no device row ever
    /// invokes them, and the outline requires the type.
    private var devicesList: some View {
        let nodeActions = CloudTreeNodeActions.bound(
            catalog: { SurfaceCatalog.shared },
            selectedWorkspaceID: { AppDelegate.shared?.tabManager?.selectedTabId },
            selectLocalWorkspace: { workspaceID in
                AppDelegate.shared?.tabManager?.selectedTabId = workspaceID
            },
            onWillMutate: { [viewModel] label in viewModel.beginOperation(label) },
            onDidMutate: { [viewModel] in viewModel.endOperation() },
            onFailure: { [viewModel] description in viewModel.noteTreeFailure(description) },
            refresh: { [viewModel] in viewModel.refresh() }
        )
        return CloudTreeOutlineView(
            machines: [],
            pendingCreates: [],
            snapshot: viewModel.catalog,
            localWorkspaces: viewModel.localWorkspaces,
            machineActions: MachineRowActions.bound(onDidMutate: {}),
            nodeActions: nodeActions,
            expansionStore: expansionStore,
            style: CloudTreeStyle.preset(id: cloudTreeStyleID) ?? .defaultStyle,
            source: .devices,
            reveal: viewModel.revealRequest,
            onDragStateChange: { [viewModel] dragging in viewModel.setTreeDragging(dragging) }
        )
        .accessibilityIdentifier("DevicesTree")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if viewModel.hasLoadedDirectory || viewModel.presenceState == .live {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.secondary.opacity(0.55))
                Text(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"))
                    .cmuxFont(size: 13, weight: .semibold)
                    .foregroundColor(.primary.opacity(0.85))
                Text(String(
                    localized: "devices.empty.subtitle",
                    defaultValue: "Sign in to cmux on another Mac and turn on Devices in Settings \u{203A} Beta Features. It appears here with its workspaces the moment it is online."
                ))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("DevicesEmptyState")
    }

    private var authCheckingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text(String(localized: "machines.auth.checking", defaultValue: "Checking your cmux account…"))
                .cmuxFont(size: 13)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("DevicesAuthCheckingView")
    }

    @ViewBuilder
    private var authGate: some View {
        if let accountFlow {
            DevicesSignInView(accountFlow: accountFlow)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.secondary.opacity(0.7))
                Text(String(localized: "devices.auth.title", defaultValue: "Sign in to see your other Macs"))
                    .cmuxFont(size: 13, weight: .semibold)
                Text(String(localized: "devices.auth.subtitle", defaultValue: "Devices shows the Macs signed into the same cmux account, with their live workspaces."))
                    .cmuxFont(size: 12)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct DevicesSignInView: View {
        let accountFlow: HostAccountFlow
        @State private var signInModel: AccountSignInModel

        init(accountFlow: HostAccountFlow) {
            self.accountFlow = accountFlow
            _signInModel = State(initialValue: AccountSignInModel(flow: accountFlow))
        }

        var body: some View {
            AccountSignInView(
                model: signInModel,
                automaticallyStartsSignIn: false,
                idleTitle: String(localized: "devices.auth.title", defaultValue: "Sign in to see your other Macs"),
                idleSubtitle: String(localized: "devices.auth.subtitle", defaultValue: "Devices shows the Macs signed into the same cmux account, with their live workspaces.")
            )
            .frame(maxWidth: 440)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("DevicesSignInView")
        }
    }
}
