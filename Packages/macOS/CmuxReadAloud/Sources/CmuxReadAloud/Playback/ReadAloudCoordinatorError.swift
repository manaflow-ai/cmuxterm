import Foundation

/// Recoverable setup errors that let the app present Read Aloud settings.
public enum ReadAloudCoordinatorError: LocalizedError {
    /// Read Aloud needs a nonempty API key and consent to send selected text to MiniMax.
    case configurationRequired

    /// A localized description safe to present without credentials or selected text.
    public var errorDescription: String? {
        String(
            localized: "readAloud.playback.configurationRequired",
            defaultValue: "Open Read Aloud settings to add your MiniMax API key and allow selected text to be sent to MiniMax.",
            table: "ReadAloudPlayback",
            bundle: .module
        )
    }
}
