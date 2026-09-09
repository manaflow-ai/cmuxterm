import Foundation

/// Fixed messages deliberately exclude provider response bodies and credentials.
enum ReadAloudTransportError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidCredential
    case authentication
    case rateLimited
    case providerRejected
    case network
    case invalidResponse
    case responseTooLarge
    case truncatedStream
    case noAudio

    static func provider(code: Int) -> Self {
        switch code {
        case 1004: .authentication
        case 1002, 1039: .rateLimited
        default: .providerRejected
        }
    }

    static func http(status: Int) -> Self {
        switch status {
        case 401, 403: .authentication
        case 429: .rateLimited
        default: .providerRejected
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            String(localized: "readAloud.transport.invalidConfiguration", defaultValue: "Choose a supported speech model, a voice, and a speed between 0.5 and 2.", table: "ReadAloudTransport", bundle: .module)
        case .invalidCredential:
            String(localized: "readAloud.transport.invalidCredential", defaultValue: "Enter a valid MiniMax API key without spaces or line breaks in Read Aloud settings.", table: "ReadAloudTransport", bundle: .module)
        case .authentication:
            String(localized: "readAloud.transport.authentication", defaultValue: "MiniMax could not authenticate this request. Check the API key in Read Aloud settings.", table: "ReadAloudTransport", bundle: .module)
        case .rateLimited:
            String(localized: "readAloud.transport.rateLimited", defaultValue: "MiniMax's speech request limit was reached. Try again later.", table: "ReadAloudTransport", bundle: .module)
        case .providerRejected:
            String(localized: "readAloud.transport.providerRejected", defaultValue: "MiniMax could not generate speech. Check your account, voice, and selected text.", table: "ReadAloudTransport", bundle: .module)
        case .network:
            String(localized: "readAloud.transport.network", defaultValue: "The connection to MiniMax failed. Check your network connection.", table: "ReadAloudTransport", bundle: .module)
        case .invalidResponse:
            String(localized: "readAloud.transport.invalidResponse", defaultValue: "MiniMax returned an invalid audio response. Read Aloud has stopped.", table: "ReadAloudTransport", bundle: .module)
        case .responseTooLarge:
            String(localized: "readAloud.transport.responseTooLarge", defaultValue: "MiniMax returned an audio message larger than the streaming safety limit. Read Aloud has stopped.", table: "ReadAloudTransport", bundle: .module)
        case .truncatedStream:
            String(localized: "readAloud.transport.truncatedStream", defaultValue: "The MiniMax audio stream ended before speech was complete.", table: "ReadAloudTransport", bundle: .module)
        case .noAudio:
            String(localized: "readAloud.transport.noAudio", defaultValue: "MiniMax did not return any playable speech for the selected text.", table: "ReadAloudTransport", bundle: .module)
        }
    }
}
