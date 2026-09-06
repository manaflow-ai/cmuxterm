import Foundation
import OwlFreshRuntimeShim

/// Owns one OWL Content Shell session and translates its native compositor events.
final class OwlFreshRuntime: @unchecked Sendable {
    struct Event: Sendable {
        let kind: Int
        let contextID: UInt32
        let loading: Bool
        let url: String?
        let title: String?
        let message: String?
    }
    typealias EventHandler = @Sendable (Event) -> Void
    private var session: OpaquePointer?
    private let handler: EventHandler
    private var callbackBox: UnmanagedCallbackBox

    private final class UnmanagedCallbackBox: @unchecked Sendable {
        let handler: EventHandler
        init(_ handler: @escaping EventHandler) { self.handler = handler }
    }

    init(shell: URL, initialURL: URL, profile: URL, handler: @escaping EventHandler) throws {
        self.handler = handler
        self.callbackBox = UnmanagedCallbackBox(handler)
        let dylib = shell
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("libowl_fresh_mojo_runtime.dylib")
        guard owl_shim_open(dylib.path) == 0 else { throw CDPError.disconnected("OWL runtime dylib unavailable") }
        guard owl_shim_global_init() == 0 else { throw CDPError.disconnected("OWL runtime initialization failed") }
        let userData = Unmanaged.passUnretained(callbackBox).toOpaque()
        let callback: OwlShimCallback = { event, userData in
            guard let event, let userData else { return }
            let box = Unmanaged<UnmanagedCallbackBox>.fromOpaque(userData).takeUnretainedValue()
            box.handler(Event(
                kind: Int(event.pointee.kind),
                contextID: UInt32(event.pointee.context_id),
                loading: event.pointee.loading,
                url: event.pointee.url.map { String(cString: $0) },
                title: event.pointee.title.map { String(cString: $0) },
                message: event.pointee.message.map { String(cString: $0) }
            ))
        }
        guard let session = owl_shim_session_create(shell.path, initialURL.absoluteString, profile.path, callback, userData) else {
            throw CDPError.disconnected("OWL Content Shell could not start")
        }
        self.session = session
        guard owl_shim_bind_all(session) == 0 else {
            owl_shim_session_destroy(session)
            self.session = nil
            throw CDPError.disconnected("OWL Mojo session binding failed")
        }
    }

    deinit {
        if let session { owl_shim_session_destroy(session) }
    }

    /// Waits for native Mojo work and dispatches callbacks without busy polling.
    func poll() { owl_shim_poll(250) }
    func navigate(_ url: URL) throws { guard let session, owl_shim_navigate(session, url.absoluteString) == 0 else { throw CDPError.notConnected } }
    func resize(width: Int, height: Int, scale: Double) throws { guard let session, owl_shim_resize(session, UInt32(max(1,width)), UInt32(max(1,height)), Float(scale)) == 0 else { throw CDPError.notConnected } }
    func focus(_ focused: Bool) throws { guard let session, owl_shim_focus(session, focused) == 0 else { throw CDPError.notConnected } }
    func mouse(kind: UInt32, x: Double, y: Double, button: UInt32, clickCount: UInt32, deltaX: Double, deltaY: Double, modifiers: UInt32) throws { guard let session, owl_shim_mouse(session, kind, Float(x), Float(y), button, clickCount, Float(deltaX), Float(deltaY), modifiers) == 0 else { throw CDPError.notConnected } }
    func key(down: Bool, keyCode: UInt32, text: String?, modifiers: UInt32) throws { guard let session, owl_shim_key(session, down, keyCode, text, modifiers) == 0 else { throw CDPError.notConnected } }
    func evaluate(_ script: String) throws -> String { guard let session else { throw CDPError.notConnected }; var result: UnsafeMutablePointer<CChar>?; guard owl_shim_eval(session, script, &result) == 0 else { throw CDPError.commandFailed("OWL JavaScript evaluation failed") }; defer { if let result { owl_shim_free(result) } }; return result.map { String(cString: $0) } ?? "null" }
    func surfaceTreeJSON() throws -> String { guard let session else { throw CDPError.notConnected }; var result: UnsafeMutablePointer<CChar>?; guard owl_shim_surface_json(session, &result) == 0 else { throw CDPError.commandFailed("OWL surface tree unavailable") }; defer { if let result { owl_shim_free(result) } }; return result.map { String(cString: $0) } ?? "{}" }
}
