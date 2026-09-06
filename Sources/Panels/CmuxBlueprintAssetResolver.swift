import CmuxAgentChat
import Foundation

/// Maps `cmux-blueprint://app/<path>` requests onto the bundled webviews app
/// directory and inflates the `.deflate` variants the build phase produces.
///
/// Pure value logic (no WebKit) so the allowlist, traversal rejection, and
/// inflate fallback can be unit tested.
struct CmuxBlueprintAssetResolver: Sendable {
    static let scheme = "cmux-blueprint"
    static let host = "app"
    static let pagePath = "/blueprint.html"

    struct Asset: Equatable, Sendable {
        let fileURL: URL
        let mimeType: String
        let isDeflated: Bool
    }

    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    /// The bundled `markdown-viewer/webviews-app` directory.
    static func defaultRootDirectory(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
    }

    /// The canvas page URL for the given theme.
    static func pageURL(isDark: Bool) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = pagePath
        components.queryItems = [URLQueryItem(name: "theme", value: isDark ? "dark" : "light")]
        return components.url!
    }

    private static let allowedExtensions: [String: String] = [
        "html": "text/html",
        "mjs": "text/javascript",
        "js": "text/javascript",
        "css": "text/css",
        "json": "application/json",
        "map": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "woff2": "font/woff2",
        "woff": "font/woff",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "txt": "text/plain",
    ]

    static func mimeType(forExtension fileExtension: String) -> String? {
        allowedExtensions[fileExtension.lowercased()]
    }

    /// Validates the request path and resolves the file to serve.
    func asset(for url: URL, fileManager: FileManager = .default) -> Asset? {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = Self.pathComponents(for: url),
              let last = components.last,
              let mimeType = Self.mimeType(forExtension: (last as NSString).pathExtension) else {
            return nil
        }
        var fileURL = rootDirectory
        for component in components {
            fileURL.appendPathComponent(component, isDirectory: false)
        }
        fileURL = fileURL.standardizedFileURL
        guard fileURL.path.hasPrefix(rootDirectory.path + "/") else { return nil }
        if fileManager.fileExists(atPath: fileURL.path) {
            return Asset(fileURL: fileURL, mimeType: mimeType, isDeflated: false)
        }
        let deflatedURL = fileURL.appendingPathExtension("deflate")
        if fileManager.fileExists(atPath: deflatedURL.path) {
            return Asset(fileURL: deflatedURL, mimeType: mimeType, isDeflated: true)
        }
        return nil
    }

    /// Reads the asset bytes, inflating deflated variants.
    func loadData(for asset: Asset) throws -> Data {
        let raw = try Data(contentsOf: asset.fileURL)
        guard asset.isDeflated else { return raw }
        guard let inflated = MarkdownViewerAssetCompression.inflate(raw) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return inflated
    }

    func responseHeaders(for asset: Asset, contentLength: Int) -> [String: String] {
        var headers = [
            "Content-Type": asset.mimeType.hasPrefix("text/") || asset.mimeType == "application/json"
                ? "\(asset.mimeType); charset=utf-8"
                : asset.mimeType,
            "Content-Length": String(contentLength),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if asset.mimeType == "text/html" {
            headers["Content-Security-Policy"] = [
                "default-src 'none'",
                "script-src 'self' 'wasm-unsafe-eval'",
                "style-src 'self' 'unsafe-inline'",
                "img-src 'self' data: blob:",
                "font-src 'self' data:",
                "connect-src 'self' data: blob:",
                "worker-src 'self' blob:",
                "object-src 'none'",
                "base-uri 'none'",
                "form-action 'none'",
            ].joined(separator: "; ")
        }
        return headers
    }

    /// Splits the request path into validated components. Rejects empty,
    /// dot, dot-dot, and hidden components as well as characters outside the
    /// bundle's file naming set.
    private static func pathComponents(for url: URL) -> [String]? {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard path.hasPrefix("/") else { return nil }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return nil }
        for component in components {
            guard !component.isEmpty,
                  !component.hasPrefix("."),
                  component.unicodeScalars.allSatisfy({ allowedPathCharacters.contains($0) }) else {
                return nil
            }
        }
        return components
    }

    private static let allowedPathCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "._-")
        return set
    }()
}
