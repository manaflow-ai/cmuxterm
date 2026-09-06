import Foundation

/// What "Send to terminal" puts into the prompt.
struct TerminalBlueprintSendOptions: Equatable, Sendable {
    /// Include the Mermaid source (the stored one, or a conversion of the elements).
    var includeMermaid = true
    /// Export a PNG next to the stored document and include its path.
    var includePNG = true
    /// Include the compact element summary.
    var includeSummary = false
    /// Include the raw Excalidraw scene JSON.
    var includeJSON = false
    /// Free text placed before the blueprint block.
    var promptPrefix: String?
    /// Press Return after inserting, so a waiting agent prompt is submitted.
    var submit = false

    init(
        includeMermaid: Bool = true,
        includePNG: Bool = true,
        includeSummary: Bool = false,
        includeJSON: Bool = false,
        promptPrefix: String? = nil,
        submit: Bool = false
    ) {
        self.includeMermaid = includeMermaid
        self.includePNG = includePNG
        self.includeSummary = includeSummary
        self.includeJSON = includeJSON
        self.promptPrefix = promptPrefix
        self.submit = submit
    }
}

struct TerminalBlueprintSendResult: Equatable, Sendable {
    var revision: Int
    var pngPath: String?
    var textLength: Int
    var formats: [String]
}

/// Builds the text pasted into the terminal for "Send to terminal".
///
/// The text is one bracketed paste, so it never ends in a newline: the user
/// (or the `submit` option) decides when it is sent.
enum TerminalBlueprintPromptComposer {
    struct Input: Equatable, Sendable {
        var revision: Int
        var elementCount: Int
        var pngPath: String?
        var mermaid: String?
        var summary: String
        var sceneJSON: String?
    }

    static func compose(_ input: Input, options: TerminalBlueprintSendOptions) -> (text: String, formats: [String]) {
        var sections: [String] = []
        var formats: [String] = []
        if let prefix = options.promptPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty {
            sections.append(prefix)
        }
        var headline = "Blueprint from this terminal (revision \(input.revision), \(input.elementCount) element\(input.elementCount == 1 ? "" : "s"))."
        if options.includePNG, let pngPath = input.pngPath {
            headline += " PNG: \(pngPath)"
            formats.append("png")
        }
        sections.append(headline)

        var wroteMermaid = false
        if options.includeMermaid, let mermaid = input.mermaid?.trimmingCharacters(in: .whitespacesAndNewlines), !mermaid.isEmpty {
            sections.append("```mermaid\n\(mermaid)\n```")
            formats.append("mermaid")
            wroteMermaid = true
        }
        // A summary stands in when Mermaid was asked for but nothing produced it.
        if options.includeSummary || (options.includeMermaid && !wroteMermaid) {
            sections.append("Canvas summary:\n```text\n\(input.summary)\n```")
            formats.append("summary")
        }
        if options.includeJSON, let sceneJSON = input.sceneJSON {
            sections.append("```json\n\(sceneJSON)\n```")
            formats.append("json")
        }
        return (sections.joined(separator: "\n"), formats)
    }
}
