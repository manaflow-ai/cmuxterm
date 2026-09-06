import Foundation
import Testing
import zlib

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("CmuxBlueprintAssetResolver")
struct CmuxBlueprintAssetResolverTests {
    private struct Fixture {
        let root: URL
        let resolver: CmuxBlueprintAssetResolver
    }

    private func zlibCompress(_ data: Data) -> Data {
        var destinationLength = compressBound(uLong(data.count))
        var destination = [UInt8](repeating: 0, count: Int(destinationLength))
        let status = data.withUnsafeBytes { source -> Int32 in
            compress2(
                &destination,
                &destinationLength,
                source.bindMemory(to: Bytef.self).baseAddress,
                uLong(data.count),
                9
            )
        }
        precondition(status == Z_OK)
        return Data(destination.prefix(Int(destinationLength)))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-blueprint-assets-\(UUID().uuidString)", isDirectory: true)
        let chunks = root.appendingPathComponent("chunks", isDirectory: true)
        let fonts = root.appendingPathComponent("excalidraw-assets/fonts/Excalifont", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("blueprint.html"))
        try zlibCompress(Data("export const x = 1;".utf8))
            .write(to: chunks.appendingPathComponent("blueprintSurface.mjs.deflate"))
        try Data([0x77, 0x4F, 0x46, 0x32]).write(to: fonts.appendingPathComponent("Excalifont-Regular.woff2"))
        try Data("secret".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent).html"))
        return Fixture(root: root, resolver: CmuxBlueprintAssetResolver(rootDirectory: root))
    }

    @Test("serves the page and raw assets with their MIME types")
    func servesRawAssets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let page = try #require(fixture.resolver.asset(for: URL(string: "cmux-blueprint://app/blueprint.html?theme=dark")!))
        #expect(page.mimeType == "text/html")
        #expect(page.isDeflated == false)
        #expect(try fixture.resolver.loadData(for: page) == Data("<html></html>".utf8))
        let font = try #require(fixture.resolver.asset(for: URL(string: "cmux-blueprint://app/excalidraw-assets/fonts/Excalifont/Excalifont-Regular.woff2")!))
        #expect(font.mimeType == "font/woff2")
        #expect(fixture.resolver.responseHeaders(for: font, contentLength: 4)["Content-Type"] == "font/woff2")
    }

    @Test("falls back to the deflated variant and inflates it")
    func inflatesDeflatedChunks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chunk = try #require(fixture.resolver.asset(for: URL(string: "cmux-blueprint://app/chunks/blueprintSurface.mjs")!))
        #expect(chunk.isDeflated)
        #expect(chunk.mimeType == "text/javascript")
        #expect(try fixture.resolver.loadData(for: chunk) == Data("export const x = 1;".utf8))
    }

    @Test("rejects traversal, hidden files, foreign hosts, and unknown extensions", arguments: [
        "cmux-blueprint://app/../outside.html",
        "cmux-blueprint://app/chunks/../../outside.html",
        "cmux-blueprint://app/.hidden.html",
        "cmux-blueprint://other/blueprint.html",
        "https://app/blueprint.html",
        "cmux-blueprint://app/blueprint.exe",
        "cmux-blueprint://app/",
        "cmux-blueprint://app/chunks/",
        "cmux-blueprint://app/missing.html",
    ])
    func rejectsUnsafeRequests(urlString: String) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try #require(URL(string: urlString))
        #expect(fixture.resolver.asset(for: url) == nil)
    }

    @Test("html responses carry a locked-down content security policy")
    func htmlHeaders() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let page = try #require(fixture.resolver.asset(for: URL(string: "cmux-blueprint://app/blueprint.html")!))
        let headers = fixture.resolver.responseHeaders(for: page, contentLength: 13)
        #expect(headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(headers["Content-Length"] == "13")
        let csp = try #require(headers["Content-Security-Policy"])
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("script-src 'self'"))
        let script = try #require(fixture.resolver.asset(for: URL(string: "cmux-blueprint://app/chunks/blueprintSurface.mjs")!))
        #expect(fixture.resolver.responseHeaders(for: script, contentLength: 1)["Content-Security-Policy"] == nil)
    }

    @Test("the page URL encodes the theme")
    func pageURL() {
        #expect(CmuxBlueprintAssetResolver.pageURL(isDark: true).absoluteString == "cmux-blueprint://app/blueprint.html?theme=dark")
        #expect(CmuxBlueprintAssetResolver.pageURL(isDark: false).absoluteString == "cmux-blueprint://app/blueprint.html?theme=light")
    }
}
