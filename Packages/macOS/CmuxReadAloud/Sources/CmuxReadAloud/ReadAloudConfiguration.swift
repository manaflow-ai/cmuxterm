import Foundation

/// Non-secret preferences for reading selected text through MiniMax.
public struct ReadAloudConfiguration: Codable, Equatable, Sendable {
    /// MiniMax speech model identifier.
    public var model: String
    /// MiniMax system or custom voice identifier.
    public var voiceID: String
    /// Synthesis speed, from 0.5 to 2.0.
    public var speed: Double

    /// Creates speech preferences without reading global settings.
    /// - Parameters:
    ///   - model: The requested MiniMax speech model.
    ///   - voiceID: The requested MiniMax voice.
    ///   - speed: The requested synthesis speed.
    public init(
        model: String = "speech-2.8-turbo",
        voiceID: String = "English_expressive_narrator",
        speed: Double = 1.0
    ) {
        self.model = model
        self.voiceID = voiceID
        self.speed = speed
    }
}
