import AppKit
import CmuxCEF

/// Pane-anchored host for a CEF-owned browser window.
///
/// CEF chrome-style browsers render natively into their own frameless
/// NSWindow. This view occupies the pane rect and keeps that window adopted
/// as a child window exactly covering the view: same process, GPU-composited,
/// no frame streaming. Visibility and geometry follow the view; input goes
/// straight to the CEF window.
@MainActor
final class CEFBrowserHostView: NSView {
    private weak var cefWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var cefWindowObservers: [NSObjectProtocol] = []
    private var isAdopted = false

    /// Whether this pane currently owns the visible browser surface. CEF's
    /// child window must stay ordered out for inactive tabs/workspaces.
    var isPaneVisible = false {
        didSet {
            guard oldValue != isPaneVisible else { return }
            reconcile()
        }
    }

    var onFocus: (() -> Void)?

    /// Whether the CEF child is currently adopted over a visible pane and is
    /// safe for focus operations. Inactive panes keep the browser alive but
    /// order its child window out, so existence of the window alone is not a
    /// focus guarantee.
    var isFocusReady: Bool {
        isAdopted &&
            isPaneVisible &&
            window != nil &&
            !isHiddenOrHasHiddenAncestor &&
            cefWindow?.isVisible == true
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in cefWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Attaches the CEF browser window to this pane.
    func attach(cefWindow: NSWindow) {
        for observer in cefWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        cefWindowObservers = []
        // CEF creates a chrome-style NSWindow before cmux can adopt it. Strip
        // every top-level affordance so the native browser surface is
        // edge-to-edge inside the pane rather than a floating titled window.
        normalizeWindowChrome(cefWindow)
        self.cefWindow = cefWindow
        // Page clicks are delivered to the adopted child window, not this
        // anchor view. Observe its key transition so cmux selection/focus
        // state follows the native CEF responder chain.
        cefWindowObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: cefWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocus?() }
            }
        )
        reconcile()
    }

    /// Detaches and hides the CEF window (pane closing or engine replacement).
    func detach() {
        if let cefWindow {
            window?.removeChildWindow(cefWindow)
            cefWindow.orderOut(nil)
        }
        cefWindow = nil
        for observer in cefWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        cefWindowObservers = []
        isAdopted = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        if let hostWindow = window {
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                windowObservers.append(center.addObserver(
                    forName: name, object: hostWindow, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcile() }
                })
            }
        }
        reconcile()
    }

    override func layout() {
        super.layout()
        reconcile()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcile()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcile()
    }

    /// Aligns the CEF window with the current pane geometry and visibility.
    func reconcile() {
        guard let cefWindow else { return }
        normalizeWindowChrome(cefWindow)
        guard isPaneVisible,
              let hostWindow = window,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 1, bounds.height > 1 else {
            if isAdopted {
                window?.removeChildWindow(cefWindow)
                cefWindow.orderOut(nil)
                isAdopted = false
            }
            return
        }
        let windowRect = convert(bounds, to: nil)
        let screenRect = hostWindow.convertToScreen(windowRect)
        if cefWindow.frame != screenRect {
            cefWindow.setFrame(screenRect, display: true)
        }
        if !isAdopted || cefWindow.parent !== hostWindow {
            cefWindow.parent?.removeChildWindow(cefWindow)
            hostWindow.addChildWindow(cefWindow, ordered: .above)
            isAdopted = true
        }
        // The window is created hidden and only appears once positioned
        // over the pane, so it can never flash at its initial bounds.
        if !cefWindow.isVisible {
            cefWindow.orderFront(nil)
        }
    }

    /// Reasserts the pane-owned window contract after CEF navigation/layout.
    /// CEF may recreate its content layer during a renderer swap, which can
    /// restore the platform's default corner mask unless this is applied on
    /// every reconciliation pass.
    private func normalizeWindowChrome(_ window: NSWindow) {
        window.styleMask = [.borderless]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 0
        window.contentView?.layer?.masksToBounds = false
        if let contentView = window.contentView {
            clearCornerMasks(in: contentView)
        }
        for button in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
            .toolbarButton
        ] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    /// CEF's chrome views can install their own rounded layer after a page
    /// navigation. Clear those masks recursively so the pane owns clipping.
    private func clearCornerMasks(in view: NSView) {
        view.layer?.cornerRadius = 0
        view.layer?.masksToBounds = false
        for child in view.subviews {
            clearCornerMasks(in: child)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // The CEF window covers this view, so a click landing here means the
        // adopted window is missing; reconcile and forward focus intent.
        onFocus?()
        reconcile()
        super.mouseDown(with: event)
    }
}
