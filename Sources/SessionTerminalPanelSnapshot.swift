import Foundation
import CmuxWorkspaces

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    /// Explicit, unscaled surface font override. Nil follows the current config.
    var fontSize: Float?
    /// In-flight workspace font requests already represented by `fontSize`.
    /// Close-history restores preserve these tokens to avoid replaying a
    /// projected request while its coordinator still owns the request.
    var fontSizeChangeTokens: [UUID]?
    var scrollback: String?
    var agent: SessionRestorableAgentSnapshot?
    var tmuxStartCommand: String?
    var hibernation: SessionAgentHibernationSnapshot?
    var resumeBinding: SurfaceResumeBindingSnapshot?
    /// Latest accepted hook event time for the surface resume binding.
    var resumeBindingEventTime: TimeInterval?
    /// Agent-hook identity kept separately when a process-detected binding is
    /// the effective terminal resume target.
    var managedAgentResumeBinding: SurfaceResumeBindingSnapshot?
    var textBoxDraft: SessionTextBoxInputDraftSnapshot?
    var isRemoteTerminal: Bool?
    var remotePTYSessionID: String?
    /// Whether the agent process was actively running when this snapshot was captured.
    /// Nil means unknown (legacy snapshots); treated as true for backwards compatibility.
    var wasAgentRunning: Bool?

    init(
        workingDirectory: String? = nil,
        fontSize: Float? = nil,
        fontSizeChangeTokens: [UUID]? = nil,
        scrollback: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil,
        tmuxStartCommand: String? = nil,
        hibernation: SessionAgentHibernationSnapshot? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        resumeBindingEventTime: TimeInterval? = nil,
        managedAgentResumeBinding: SurfaceResumeBindingSnapshot? = nil,
        textBoxDraft: SessionTextBoxInputDraftSnapshot? = nil,
        isRemoteTerminal: Bool? = nil,
        remotePTYSessionID: String? = nil,
        wasAgentRunning: Bool? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.fontSize = fontSize
        self.fontSizeChangeTokens = fontSizeChangeTokens
        self.scrollback = scrollback
        self.agent = agent
        self.tmuxStartCommand = tmuxStartCommand
        self.hibernation = hibernation
        self.resumeBinding = resumeBinding
        self.resumeBindingEventTime = resumeBindingEventTime
        self.managedAgentResumeBinding = managedAgentResumeBinding
        self.textBoxDraft = textBoxDraft
        self.isRemoteTerminal = isRemoteTerminal
        self.remotePTYSessionID = remotePTYSessionID
        self.wasAgentRunning = wasAgentRunning
    }
}

extension SessionTerminalPanelSnapshot: WorkspaceSessionRemoteRestoreTerminalSnapshot {}
