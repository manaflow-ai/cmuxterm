import Foundation

/// Safe descriptions for local audio failures, without underlying device details.
enum ReadAloudPlaybackError: LocalizedError {
    case outputUnavailable
    case incompleteSample

    var errorDescription: String? {
        switch self {
        case .outputUnavailable:
            String(
                localized: "readAloud.playback.outputUnavailable",
                defaultValue: "Audio output is unavailable. Check your sound output device and try again.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        case .incompleteSample:
            String(
                localized: "readAloud.playback.incompleteSample",
                defaultValue: "The speech service returned incomplete audio. Please try again.",
                table: "ReadAloudPlayback",
                bundle: .module
            )
        }
    }
}
