import Foundation

/// Lazily partitions text without trimming, preferring natural speech boundaries.
struct ReadAloudTextChunks: Sendable {
    private let text: String
    private var position: String.Index
    private let maximumUTF16Count: Int

    init(text: String, maximumUTF16Count: Int = 9_999) {
        precondition(maximumUTF16Count >= 2)
        self.text = text
        self.position = text.startIndex
        self.maximumUTF16Count = maximumUTF16Count
    }

    mutating func next() throws -> String? {
        let remaining = text[position...]
        try Task.checkCancellation()
        guard position < text.endIndex else { return nil }
        let start = position
        var end = start
        var units = 0
        var paragraph: String.Index?
        var sentence: String.Index?
        var whitespace: String.Index?

        while end < text.endIndex {
            try Task.checkCancellation()
            let character = remaining[end]
            let count = character.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
            guard units + count <= maximumUTF16Count else { break }
            units += count
            end = remaining.index(after: end)
            if character.isNewline {
                paragraph = end
            } else if ".!?。！？".contains(character) {
                sentence = end
            } else if character.isWhitespace {
                whitespace = end
            }
        }

        if end == text.endIndex {
            position = end
        } else if end > start {
            position = paragraph ?? sentence ?? whitespace ?? end
        } else {
            // A single extended grapheme can exceed the provider limit. Split only
            // at scalar boundaries in that exceptional case, never inside UTF-16 pairs.
            var scalarEnd = start
            for scalar in text[start...].unicodeScalars {
                try Task.checkCancellation()
                let count = scalar.value > 0xFFFF ? 2 : 1
                guard units + count <= maximumUTF16Count else { break }
                units += count
                scalarEnd = text.unicodeScalars.index(after: scalarEnd)
            }
            position = scalarEnd
        }
        return String(text[start..<position])
    }
}
