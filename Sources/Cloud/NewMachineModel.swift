import Foundation
import Observation

struct MachineSizeOption: Equatable, Sendable {
    let memoryMb: Int
    let diskMb: Int

    init?(memoryMb: Int) {
        switch memoryMb {
        case 4096: self.init(memoryMb: memoryMb, diskMb: 16384)
        case 8192: self.init(memoryMb: memoryMb, diskMb: 32768)
        case 16384: self.init(memoryMb: memoryMb, diskMb: 65536)
        case 24576: self.init(memoryMb: memoryMb, diskMb: 98304)
        case 32768: self.init(memoryMb: memoryMb, diskMb: 131072)
        case 65536: self.init(memoryMb: memoryMb, diskMb: 131072)
        default: return nil
        }
    }

    private init(memoryMb: Int, diskMb: Int) {
        self.memoryMb = memoryMb
        self.diskMb = diskMb
    }

    /// The localized RAM value shown as the selected picker title.
    var title: String {
        String(
            format: String(localized: "machines.new.size.option", defaultValue: "%d GB RAM"),
            memoryMb / 1024
        )
    }

    /// The localized disk value shown below the selected picker title.
    var detail: String {
        String(
            format: String(localized: "machines.new.size.detail", defaultValue: "%d GB disk included"),
            diskMb / 1024
        )
    }

    /// The localized disk value shown in the resource summary.
    var diskTitle: String {
        String(
            format: String(localized: "machines.new.size.gb", defaultValue: "%d GB"),
            diskMb / 1024
        )
    }

    /// The localized, compact row title shown in the size menu.
    var menuTitle: String {
        String(
            format: String(localized: "machines.new.size.menu", defaultValue: "%1$d GB RAM · %2$d GB disk"),
            memoryMb / 1024,
            diskMb / 1024
        )
    }
}

/// State behind the New Machine sheet: what the person picked, what the plan
/// allows, and the one create call. The model never talks to the backend
/// itself and never waits for it: ``create()`` packs the choice into a
/// ``MachineCreateRequest``, hands it to the injected `submit` (the
/// ``MachineCreateCoordinator`` in the app), and finishes the sheet the
/// moment the CLI run is launched. The machine coming up is the
/// coordinator's business from then on; the Machines panel shows it.
@MainActor
@Observable
final class NewMachineModel {
    /// Which create flow the sheet fronts.
    enum Mode: Equatable {
        /// `cmux vm new`: a fresh machine with its own persistent home.
        case newMachine
        /// `cmux vm base open --workspace <id>`: the persistent Base slot's
        /// first provisioning. Base has no size choice (the backend sizes it)
        /// and no name (it is always "Base").
        case base(workspaceID: UUID)
    }

    /// An existing machine the new one can be forked from.
    struct SourceMachine: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    /// Where the new machine starts: the default image, or a snapshot of an
    /// existing machine. Forks inherit the source's size, so the size picker
    /// hides when a source is chosen.
    enum Source: Equatable {
        case image
        case fork(SourceMachine)
    }

    /// How the sheet ended.
    enum Outcome: Equatable {
        /// The create was launched and now runs in the background.
        case submitted
        case cancelled
    }

    /// Launches the create described by the request; returns false when it
    /// could not start (a sign-out raced the click), in which case the sheet
    /// stays up and says so.
    typealias Submit = @MainActor (MachineCreateRequest) -> Bool

    /// The base-image sizes the backend exposes, in ascending memory order.
    /// Each row is a validated Freestyle snapshot: 4/16, 8/32, 16/64,
    /// 24/96, 32/128, or 64/128 GB of memory/disk. The server's list trims
    /// this set for plan limits. The 128 MiB BusyBox image is intentionally
    /// not a coding-machine option because it has no baked dev tools.
    nonisolated static let memoryOptionsMb: [Int] = [4096, 8192, 16384, 24576, 32768, 65536]
    static let planMachineMemoryMb = 8192
    /// The pre-ladder backend default. It is used only when the server omits
    /// `limits.memoryOptionsMb`, so the client does not send an unsupported
    /// `--size` flag during a rolling upgrade.
    static let legacyPlanMachineMemoryMb = 20480
    /// Mirrors `maxMemoryMbForPlan`: development and paid plans may use the
    /// largest supported base image unless an operator sets a lower ceiling.
    /// Each machine has its own resources within the paid machine allowance.
    static func maxMemoryMb(planId: String?) -> Int {
        _ = planId
        return memoryOptionsMb.max() ?? planMachineMemoryMb
    }
    /// Mirrors `defaultMemoryMbForPlan`: the provider sizing profile, never above the max.
    static func defaultMemoryMb(planId: String?) -> Int {
        min(planMachineMemoryMb, maxMemoryMb(planId: planId))
    }

    let mode: Mode
    let plan: MachinePlanSnapshot?
    let availableMemoryOptionsMb: [Int]
    /// Machines the person can fork from, in the order the fleet lists them.
    let sourceOptions: [SourceMachine]
    var memoryMb: Int
    var source: Source = .image
    /// Why the create could not be launched; nil once a retry starts. Failures
    /// of the create itself never land here: by then the sheet is gone and the
    /// Machines panel row carries them.
    private(set) var errorText: String?
    private(set) var outcome: Outcome?

    /// Set by the presenter: called once when the sheet should close.
    var onFinished: (@MainActor (Outcome) -> Void)?

    private let submit: Submit

    init(
        mode: Mode,
        plan: MachinePlanSnapshot?,
        memoryOptionsMb: [Int] = [],
        sourceOptions: [SourceMachine] = [],
        submit: @escaping Submit
    ) {
        self.mode = mode
        self.plan = plan
        self.sourceOptions = mode == .newMachine ? sourceOptions : []
        let serverOptions = Set(memoryOptionsMb.filter { MachineSizeOption(memoryMb: $0) != nil }).sorted()
        // An empty list means an older control plane did not advertise the
        // ladder. Preserve its 20 GiB default and omit --size entirely.
        self.availableMemoryOptionsMb = serverOptions
        self.submit = submit
        self.memoryMb = serverOptions.isEmpty
            ? Self.legacyPlanMachineMemoryMb
            : Self.defaultMemoryMb(planId: plan?.planId, options: serverOptions)
    }

    static func defaultMemoryMb(planId: String?, options: [Int] = memoryOptionsMb) -> Int {
        let allowed = options.filter { $0 <= maxMemoryMb(planId: planId) }.sorted()
        if allowed.contains(planMachineMemoryMb) { return planMachineMemoryMb }
        return allowed.first ?? planMachineMemoryMb
    }

    var isBaseSetup: Bool {
        if case .base = mode { return true }
        return false
    }

    /// Base is sized by the backend and a fork inherits its source's size;
    /// only a `vm new` from the default image takes `--size`.
    var supportsSize: Bool { mode == .newMachine && source == .image && !availableMemoryOptionsMb.isEmpty }

    /// Only a fresh machine can start from another machine.
    var supportsSource: Bool { mode == .newMachine && !sourceOptions.isEmpty }

    /// The `SourceMachine.id` the picker binds to; empty string means the default image.
    var sourceSelectionID: String {
        get {
            if case .fork(let machine) = source { return machine.id }
            return ""
        }
        set {
            if let machine = sourceOptions.first(where: { $0.id == newValue }) {
                source = .fork(machine)
            } else {
                source = .image
            }
        }
    }
    var memoryOptions: [Int] {
        let ceiling = Self.maxMemoryMb(planId: plan?.planId)
        return availableMemoryOptionsMb.filter { $0 <= ceiling }.sorted()
    }

    var selectedSize: MachineSizeOption? { MachineSizeOption(memoryMb: memoryMb) }

    /// "1 of 1 machine" from the panel's meter; nil when the plan is unknown.
    /// Uncapped plans read "2 machines in use".
    var planMeterText: String? {
        guard let plan else { return nil }
        guard let maxActiveVms = plan.maxActiveVms else {
            if plan.activeCount == 1 {
                return String(localized: "machines.new.plan.unlimited.single", defaultValue: "1 machine in use")
            }
            let format = String(localized: "machines.new.plan.unlimited", defaultValue: "%1$d machines in use")
            return String(format: format, plan.activeCount)
        }
        // The new machine counts toward the ceiling once it exists.
        let format = plan.isSingleMachinePlan
            ? String(localized: "machines.new.plan.single", defaultValue: "%1$d of 1 machine in use")
            : String(localized: "machines.new.plan.multi", defaultValue: "%1$d of %2$d machines in use")
        return String(format: format, plan.activeCount, maxActiveVms)
    }

    /// The free plan's access window, so nobody is surprised a week later.
    var freeAccessNoteText: String? {
        guard let plan, !plan.isPaidPlan, plan.freeAccessWindowDays > 0 else { return nil }
        let format = String(
            localized: "machines.new.plan.freeWindow",
            defaultValue: "Free plan: this machine stays reachable for %d days. Upgrade to keep it."
        )
        return String(format: format, plan.freeAccessWindowDays)
    }

    static func memoryLabel(mb: Int) -> String {
        if mb % 1024 == 0 {
            let format = String(localized: "machines.new.size.gb", defaultValue: "%d GB")
            return String(format: format, mb / 1024)
        }
        let format = String(localized: "machines.new.size.mb", defaultValue: "%d MB")
        return String(format: format, mb)
    }

    /// The exact CLI invocation the create runs. Freestyle's base snapshot is
    /// selected by the requested size; no kind, name, or image is user input.
    /// `--focus false` is what makes the sheet's create a background one: the
    /// machine still opens (its own workspace, the Base placeholder) but the
    /// CLI never selects that workspace or moves keyboard focus out of the
    /// one the person is working in when it lands.
    var cliArguments: [String] {
        switch mode {
        case .newMachine:
            if case .fork(let machine) = source {
                // The backend snapshots the source and starts the new machine
                // from that snapshot; size and image come from the source.
                return ["vm", "fork", machine.id, "--focus", "false"]
            }
            var arguments = ["vm", "new", "--base"]
            if supportsSize { arguments += ["--size", String(memoryMb)] }
            arguments += ["--focus", "false"]
            return arguments
        case .base(let workspaceID):
            return [
                "vm", "base", "open",
                "--workspace", workspaceID.uuidString,
                "--base",
                "--focus", "false",
            ]
        }
    }

    /// The request the coordinator tracks for this sheet's choices.
    var createRequest: MachineCreateRequest {
        let requestSource: MachineCreateRequest.Source
        if mode == .newMachine, case .fork(let machine) = source {
            requestSource = .fork(vmID: machine.id, name: machine.name)
        } else {
            requestSource = .image
        }
        return MachineCreateRequest(
            mode: mode,
            kind: .base,
            name: nil,
            arguments: cliArguments,
            source: requestSource
        )
    }

    /// Launches the create and finishes the sheet. Nothing here waits on the
    /// machine: control returns to the person as soon as the CLI is running.
    func create() {
        guard outcome == nil else { return }
        errorText = nil
        guard submit(createRequest) else {
            errorText = String(
                localized: "machines.new.error.launch",
                defaultValue: "cmux could not start the create command. Sign in and try again."
            )
            return
        }
        finish(.submitted)
    }

    func cancel() {
        guard outcome == nil else { return }
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        self.outcome = outcome
        onFinished?(outcome)
    }
}
