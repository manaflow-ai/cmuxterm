import Foundation
import WebKit

/// Serves the bundled Excalidraw canvas page and its chunks to the blueprint
/// web view. File reads and inflation happen off the main actor; every
/// `WKURLSchemeTask` callback stays on the main actor and is skipped once
/// WebKit stops the task.
@MainActor
final class CmuxBlueprintURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = CmuxBlueprintAssetResolver.scheme

    private typealias ActiveTask = (task: WKURLSchemeTask, operation: Task<Void, Never>?)

    private let resolver: CmuxBlueprintAssetResolver
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]

    init(resolver: CmuxBlueprintAssetResolver) {
        self.resolver = resolver
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let asset = resolver.asset(for: requestURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks[taskID] = (task: urlSchemeTask, operation: nil)
        let resolver = resolver
        let operation = Task { @MainActor [weak self] in
            let loaded: Result<Data, any Error> = await Task.detached(priority: .userInitiated) {
                Result { try resolver.loadData(for: asset) }
            }.value
            guard let self, let active = self.activeTasks.removeValue(forKey: taskID) else { return }
            switch loaded {
            case .success(let data):
                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: resolver.responseHeaders(for: asset, contentLength: data.count)
                ) ?? URLResponse(
                    url: requestURL,
                    mimeType: asset.mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )
                active.task.didReceive(response)
                active.task.didReceive(data)
                active.task.didFinish()
            case .failure(let error):
                active.task.didFailWithError(error)
            }
        }
        if activeTasks[taskID] != nil {
            activeTasks[taskID] = (task: urlSchemeTask, operation: operation)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.operation?.cancel()
    }
}
