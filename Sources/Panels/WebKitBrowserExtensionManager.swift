import Foundation
import WebKit
import ObjectiveC
import CmuxBrowser

/// Owns WebKit extension contexts for one cmux browser profile.
/// Controllers are intentionally profile-scoped so extension state is isolated
/// and survives pane recreation through the profile's website data store.
@MainActor
final class WebKitBrowserExtensionManager {
    let controller: WKWebExtensionController?
    private(set) var loadError: Error?
    private var contexts: [WKWebExtensionContext] = []
    /// Loading tasks are retained until completion so a pane created during
    /// startup cannot drop its service worker before the first navigation.
    private var loadTasks: [Task<Void, Never>] = []

    init(profileID: UUID, directories: [URL]) {
        guard #available(macOS 15.4, *), !directories.isEmpty else {
            controller = nil
            return
        }
        let configuration = WKWebExtensionController.Configuration(
            identifier: "com.cmux.browser.\(profileID.uuidString.lowercased())"
        )
        let controller = WKWebExtensionController(configuration: configuration)
        self.controller = controller
        for directory in directories {
            do {
                let webExtension = try WKWebExtension(resourceBaseURL: directory)
                let context = try WKWebExtensionContext(for: webExtension)
                contexts.append(context)
                let task = Task { [weak self, weak controller] in
                    do {
                        try await controller?.load(context)
                    } catch {
                        self?.loadError = error
                    }
                }
                loadTasks.append(task)
            } catch {
                loadError = error
            }
        }
    }


    static func retain(_ manager: WebKitBrowserExtensionManager, on configuration: WKWebViewConfiguration) {
        objc_setAssociatedObject(configuration, Unmanaged.passUnretained(AssociationKey.self).toOpaque(), manager, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private final class AssociationKey {}
}
