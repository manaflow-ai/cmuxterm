import Foundation

/// Browser runtime used when cmux opens browser tabs and intercepted links.
public enum BrowserEngine: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    /// Uses the embedded WebKit browser surface inside cmux.
    case webKit = "webkit"

    /// Routes browser tabs and intercepted links to the macOS default browser.
    case systemDefault = "systemDefault"

    public var id: String { rawValue }

    public var usesEmbeddedBrowser: Bool {
        self == .webKit
    }
}
