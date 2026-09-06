@preconcurrency import Foundation

/// Resolves the pinned, downloadable Chromium runtime used by opt-in panes.
///
/// The manifest intentionally contains only URLs and metadata. The executable
/// is downloaded into cmux's application-support directory on first use and is
/// never checked into the repository. Keeping the version in source makes the
/// runtime reproducible and prevents a page or a settings file from selecting
/// an arbitrary executable.
struct ChromiumRuntimeManifest: Sendable {
    private static let productionVersion = "owl-chromium-7523a3a72320"

    let version: String
    let artifacts: [String: ChromiumRuntimeArtifact]

    /// The production manifest for the current macOS process architecture.
    ///
    /// The reviewed OWL release publishes a native macOS arm64 Content Shell
    /// plus its Mojo runtime dylib. The URL and source commit are pinned; page
    /// content and settings cannot select an arbitrary executable.
    static let production = ChromiumRuntimeManifest(
        version: productionVersion,
        artifacts: [
            "arm64": ChromiumRuntimeArtifact(
                version: productionVersion,
                platform: "mac-arm64",
                downloadURL: URL(string: "https://github.com/manaflow-ai/chromium/releases/download/owl-chromium-7523a3a72320/owl-chromium-runtime-macos-arm64-7523a3a72320.tar.gz")!,
                sha256: "08f48d9c5a220b94a803d935a174ddc93303cd495de16b6474bd907faf62dee0"
            ),
        ]
    )

    /// Returns the artifact matching the host architecture, or `nil` when the
    /// current process architecture is not supported by the manifest.
    func artifact(for architecture: String = Self.processArchitecture) -> ChromiumRuntimeArtifact? {
        artifacts[architecture]
    }

    /// The normalized architecture spelling used by the manifest.
    static var processArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unsupported"
#endif
    }
}
