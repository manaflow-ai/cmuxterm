import Foundation

/// The persisted blueprint of one terminal surface.
///
/// `sceneJSON` is the Excalidraw scene (`{elements, appState, files}`) exactly
/// as the web canvas serialized it. `revision` is bumped by every accepted
/// mutation, whichever side authored it, so agents can detect that the user
/// edited the canvas since they last read it.
struct TerminalBlueprintDocument: Codable, Equatable, Sendable {
    enum Author: String, Codable, Sendable {
        case user
        case agent
        case restore
    }

    static let currentVersion = 1

    var version: Int
    var surfaceID: UUID
    var sceneJSON: String
    /// The most recent Mermaid source that produced (part of) the scene, if any.
    var mermaidSource: String?
    var revision: Int
    var updatedAt: Date
    var lastAuthor: Author

    init(
        version: Int = TerminalBlueprintDocument.currentVersion,
        surfaceID: UUID,
        sceneJSON: String,
        mermaidSource: String? = nil,
        revision: Int,
        updatedAt: Date,
        lastAuthor: Author
    ) {
        self.version = version
        self.surfaceID = surfaceID
        self.sceneJSON = sceneJSON
        self.mermaidSource = mermaidSource
        self.revision = revision
        self.updatedAt = updatedAt
        self.lastAuthor = lastAuthor
    }
}
