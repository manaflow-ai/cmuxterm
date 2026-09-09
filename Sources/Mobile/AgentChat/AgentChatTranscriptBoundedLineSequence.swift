import Foundation

extension AgentChatTranscriptReader {
    /// Lazily decodes bounded transcript records without building a line array.
    struct BoundedLineSequence: Sequence {
        let data: Data
        let maximumLineCount: Int

        func makeIterator() -> AgentChatTranscriptBoundedLineIterator {
            AgentChatTranscriptBoundedLineIterator(
                data: data,
                maximumLineCount: Swift.max(0, maximumLineCount),
                cursor: data.startIndex
            )
        }
    }
}
