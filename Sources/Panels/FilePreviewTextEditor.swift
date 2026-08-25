import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import CmuxSyntaxHighlighting
import SwiftUI

@MainActor
protocol FilePreviewTextEditingPanel: AnyObject {
    var textContent: String { get }
    var textContentRevision: Int { get }

    func attachTextView(_ textView: NSTextView)
    func retryPendingFocus()
    func updateTextContent(_ nextContent: String)
    @discardableResult
    func saveTextContent() -> Task<Void, Never>?
}

extension FilePreviewTextEditingPanel {
    var textContentRevision: Int { 0 }
}

struct FilePreviewTextEditor<PanelModel>: NSViewRepresentable where PanelModel: ObservableObject & FilePreviewTextEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool
<<<<<<< HEAD
    /// Opaque Ghostty panel color. The ruler is not a hole onto that
    /// surface, so it always paints this even when the text view is clear.
    let gutterBackgroundColor: NSColor
    /// Whether long lines soft-wrap at the editor's right edge. Sourced from
    /// the persisted `fileEditor.wordWrap` setting; updates apply live.
    let wordWrap: Bool
    /// Default point size for newly opened editors. An existing editor follows
    /// the default until the user has zoomed it independently.
    let fontSize: Double
    /// Default AppKit font family. Empty keeps the monospaced system font.
    let fontFamily: String
    /// Paragraph line-height multiplier. `1.0` keeps natural font leading.
    let lineHeight: Double
    /// Absolute path used only to resolve a highlight.js language.
    var filePath: String = ""

    @LiveSetting(\.fileEditor.syntaxHighlighting) private var syntaxHighlighting
    @LiveSetting(\.fileEditor.lineNumbers) private var lineNumbers
    @LiveSetting(\.fileEditor.indentGuides) private var indentGuides
    @LiveSetting(\.fileEditor.currentLineHighlight) private var currentLineHighlight
    @LiveSetting(\.fileEditor.tabWidth) private var tabWidth
=======
    /// Persisted editor settings are observed only while this text editor is mounted.
    /// Keeping them here prevents Settings changes from invalidating unrelated preview
    /// surfaces, especially the Markdown WebView while a font-family field is edited.
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled
    @AppStorage(FilePreviewFontSizeSettings.key) private var fileEditorFontSize = FilePreviewFontSizeSettings.defaultPointSize
    @AppStorage(FilePreviewFontFamilySettings.key) private var fileEditorFontFamily = FilePreviewFontFamilySettings.defaultFamily
    @AppStorage(FilePreviewLineHeightSettings.key) private var fileEditorLineHeight = FilePreviewLineHeightSettings.defaultMultiplier
>>>>>>> 92b2359a55 (perf(file-editor): scope settings observation to editor)

    func makeCoordinator() -> Coordinator {
        Coordinator(
            panel: panel,
            filePath: filePath,
            editorSettings: FilePreviewEditorSettings(defaults: .standard)
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.isHidden = !isVisibleInUI
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = drawsBackground

        let textView = SavingTextView.makeFilePreviewTextView(
            fontFamily: fileEditorFontFamily,
            fontSize: CGFloat(fileEditorFontSize),
            lineHeight: CGFloat(fileEditorLineHeight)
        )
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.onPreviewFontDidChange = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.handlePreviewFontChange(in: textView)
        }
        textView.drawsBackground = drawsBackground
        textView.string = panel.textContent
        context.coordinator.lastAppliedContentRevision = panel.textContentRevision
        context.coordinator.isHighlightingVisible = isVisibleInUI
        textView.configurePreviewTypography(
            fontFamily: fileEditorFontFamily,
            defaultFontSize: CGFloat(fileEditorFontSize),
            lineHeight: CGFloat(fileEditorLineHeight)
        )
        panel.attachTextView(textView)

        scrollView.documentView = textView
<<<<<<< HEAD
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        Self.installChrome(on: scrollView, textView: textView)
=======
        textView.applyFilePreviewWordWrap(fileEditorWordWrap, scrollView: scrollView)
>>>>>>> 92b2359a55 (perf(file-editor): scope settings observation to editor)
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground,
            gutterBackgroundColor: gutterBackgroundColor
        )
        Self.applyChromeSettings(
            to: scrollView,
            lineNumbers: lineNumbers,
            indentGuides: indentGuides,
            currentLineHighlight: currentLineHighlight,
            tabWidth: tabWidth
        )
        Self.refreshChrome(on: scrollView, textView: textView)
        if isVisibleInUI {
            context.coordinator.scheduleHighlight(
                for: textView,
                enabled: syntaxHighlighting,
                defaultColor: themeForegroundColor,
                force: true
            )
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let panelIdentity = ObjectIdentifier(panel)
        let panelChanged = context.coordinator.panelIdentity != panelIdentity
        context.coordinator.filePath = filePath
        let becameVisible = isVisibleInUI && !context.coordinator.isHighlightingVisible
        context.coordinator.isHighlightingVisible = isVisibleInUI
        scrollView.isHidden = !isVisibleInUI
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground,
            gutterBackgroundColor: gutterBackgroundColor
        )
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        context.coordinator.panel = panel
        context.coordinator.panelIdentity = panelIdentity
        textView.panel = panel
        textView.applyFilePreviewTextEditorInsets()
        textView.applyFilePreviewWordWrap(fileEditorWordWrap, scrollView: scrollView)
        panel.attachTextView(textView)
        Self.applyChromeSettings(
            to: scrollView,
            lineNumbers: lineNumbers,
            indentGuides: indentGuides,
            currentLineHighlight: currentLineHighlight,
            tabWidth: tabWidth
        )

        let contentChanged = panelChanged || (panel.textContentRevision == 0
            ? textView.string != panel.textContent
            : context.coordinator.lastAppliedContentRevision != panel.textContentRevision)
        let selectedRanges = contentChanged ? textView.selectedRanges : []
        let visibleOrigin = scrollView.contentView.bounds.origin
        context.coordinator.withPanelUpdate {
            // Reconcile external content before formatting the text storage. Both
            // operations can emit NSText.didChangeNotification, so they must share
            // the same delegate guard or a reload can publish stale editor text.
            if contentChanged {
                textView.string = panel.textContent
                context.coordinator.lastAppliedContentRevision = panel.textContentRevision
            }
            textView.configurePreviewTypography(
                fontFamily: fileEditorFontFamily,
                defaultFontSize: CGFloat(fileEditorFontSize),
                lineHeight: CGFloat(fileEditorLineHeight)
            )
            if contentChanged {
                // Reapply attributes after replacing the string; NSTextView can
                // reset typing/storage attributes when its content is replaced.
                textView.applyCurrentPreviewFont()
                textView.applyCurrentPreviewLineHeight()
            }
        }
        if contentChanged {
            let contentLength = (textView.string as NSString).length
            let clampedRanges = selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let location = min(range.location, contentLength)
                let length = min(range.length, contentLength - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
            textView.setSelectedRanges(clampedRanges, affinity: .downstream, stillSelecting: false)
            scrollView.layoutSubtreeIfNeeded()
            let clipView = scrollView.contentView
            let constrained = clipView.constrainBoundsRect(
                NSRect(origin: visibleOrigin, size: clipView.bounds.size)
            )
            clipView.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        if isVisibleInUI {
            context.coordinator.scheduleHighlight(
                for: textView,
                enabled: syntaxHighlighting,
                defaultColor: themeForegroundColor,
                force: contentChanged || becameVisible
            )
        } else {
            context.coordinator.cancelHighlight()
        }
        Self.refreshChrome(on: scrollView, textView: textView)
    }

    static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool,
        gutterBackgroundColor: NSColor? = nil
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = resolvedBackgroundColor
            // Do not set `textView.textColor` — that flattens token colors on every SwiftUI tick.
            textView.insertionPointColor = foregroundColor
            textView.typingAttributes[.foregroundColor] = foregroundColor
            if let font = textView.font {
                textView.typingAttributes[.font] = font
            }
            let tokenTheme = TokenTheme(appearance: textView.effectiveAppearance)
            if let overlay = FilePreviewEditorChromeOverlay.installed(in: textView) {
                overlay.currentLineColor = tokenTheme.currentLineFillColor
                overlay.indentGuideColor = tokenTheme.indentGuideColor
            }
            if let gutter = scrollView.verticalRulerView as? FilePreviewLineNumberGutterView {
                gutter.tokenTheme = tokenTheme
                // The ruler is a sibling of the document view, not a hole
                // onto the Ghostty surface. `backgroundColor` is often
                // `.clear` (glass / terminal show-through); paint the
                // composited panel color instead so numbers sit on the same
                // field as the text.
                let gutterFill = gutterBackgroundColor ?? backgroundColor
                gutter.editorBackgroundColor = gutterFill
                gutter.drawsEditorBackground = gutterFill.alphaComponent >= 0.999
            }
        }
    }

    static func installChrome(on scrollView: NSScrollView, textView: NSTextView) {
        if scrollView.verticalRulerView == nil {
            let gutter = FilePreviewLineNumberGutterView(scrollView: scrollView, orientation: .verticalRuler)
            gutter.clientView = textView
            scrollView.verticalRulerView = gutter
        }
        if FilePreviewEditorChromeOverlay.installed(in: textView) == nil {
            let overlay = FilePreviewEditorChromeOverlay(frame: textView.bounds)
            overlay.textView = textView
            overlay.autoresizingMask = [.width, .height]
            textView.addSubview(overlay)
        }
    }

    static func applyChromeSettings(
        to scrollView: NSScrollView,
        lineNumbers: Bool,
        indentGuides: Bool,
        currentLineHighlight: Bool,
        tabWidth: Int
    ) {
        scrollView.hasVerticalRuler = lineNumbers
        scrollView.rulersVisible = lineNumbers
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let catalog = FileEditorCatalogSection()
        let effectiveTabWidth = catalog.tabWidthRange.contains(tabWidth)
            ? tabWidth : catalog.tabWidth.defaultValue
        textView.applyFilePreviewTabWidth(effectiveTabWidth)
        guard let overlay = FilePreviewEditorChromeOverlay.installed(in: textView) else { return }
        overlay.showsCurrentLine = currentLineHighlight
        overlay.showsIndentGuides = indentGuides
        overlay.tabWidth = effectiveTabWidth
        overlay.needsDisplay = true
    }

    static func refreshChrome(
        on scrollView: NSScrollView,
        textView: NSTextView
    ) {
        // Skip all line-index maintenance while the ruler is hidden; the
        // gutter flags a full rebuild for when line numbers come back on.
        if scrollView.rulersVisible,
           let gutter = scrollView.verticalRulerView as? FilePreviewLineNumberGutterView {
            gutter.reloadLineIndex(from: textView.string, textFont: textView.font)
        }
        // The overlay geometry can change without a text change (for example
        // after wrapping or resizing), so frame synchronization is unconditional.
        FilePreviewEditorChromeOverlay.installed(in: textView)?.syncFrame(to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: PanelModel
        fileprivate var panelIdentity: ObjectIdentifier
        var filePath: String
        var isApplyingPanelUpdate = false
        var lastAppliedContentRevision: Int?
        var isHighlightingVisible = false
        // `FilePreviewSyntaxStyler` owns the cancellable task and cancels it in
        // its own deinitializer. Keeping teardown in that owner also avoids an
        // actor-isolated generic deinitializer that older Swift optimizers can
        // crash while compiling the Release WMO build.
        private let styler = FilePreviewSyntaxStyler()
        private let editorSettings: FilePreviewEditorSettings

        init(
            panel: PanelModel,
            filePath: String,
            editorSettings: FilePreviewEditorSettings
        ) {
            self.panel = panel
            self.panelIdentity = ObjectIdentifier(panel)
            self.filePath = filePath
            self.editorSettings = editorSettings
        }

        /// Runs a representable-driven text update while suppressing delegate
        /// callbacks caused by content or attribute synchronization.
        @discardableResult
        func withPanelUpdate<Result>(_ body: () -> Result) -> Result {
            let previousValue = isApplyingPanelUpdate
            isApplyingPanelUpdate = true
            defer { isApplyingPanelUpdate = previousValue }
            return body()
        }

        deinit {}
        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? NSTextView else { return }
            panel.updateTextContent(textView.string)
            lastAppliedContentRevision = panel.textContentRevision
            guard isHighlightingVisible else { return }
            scheduleHighlight(
                for: textView,
                enabled: editorSettings.isEnabled(
                    key: editorSettings.catalog.syntaxHighlighting.userDefaultsKey,
                    default: editorSettings.catalog.syntaxHighlighting.defaultValue
                ),
                defaultColor: textView.insertionPointColor,
                force: true
            )
            if let scrollView = textView.enclosingScrollView {
                FilePreviewTextEditor<PanelModel>.refreshChrome(
                    on: scrollView,
                    textView: textView
                )
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            FilePreviewEditorChromeOverlay.installed(in: textView)?.needsDisplay = true
            if let gutter = textView.enclosingScrollView?.verticalRulerView
                as? FilePreviewLineNumberGutterView {
                gutter.needsDisplay = true
            }
        }

        func handlePreviewFontChange(in textView: NSTextView) {
            guard isHighlightingVisible else { return }
            textView.applyFilePreviewTabWidth(editorSettings.tabWidth)
            scheduleHighlight(
                for: textView,
                enabled: editorSettings.isEnabled(
                    key: editorSettings.catalog.syntaxHighlighting.userDefaultsKey,
                    default: editorSettings.catalog.syntaxHighlighting.defaultValue
                ),
                defaultColor: textView.insertionPointColor,
                force: true
            )
            if let scrollView = textView.enclosingScrollView {
                FilePreviewTextEditor<PanelModel>.refreshChrome(
                    on: scrollView,
                    textView: textView
                )
            }
        }

        func cancelHighlight() {
            styler.cancel()
        }

        func scheduleHighlight(
            for textView: NSTextView,
            enabled: Bool,
            defaultColor: NSColor,
            force: Bool
        ) {
            guard isHighlightingVisible else { return }
            styler.schedule(
                for: textView,
                contentRevision: panel.textContentRevision,
                filePath: filePath,
                enabled: enabled,
                defaultColor: defaultColor,
                theme: TokenTheme(appearance: textView.effectiveAppearance),
                force: force
            )
        }
    }
}

enum FilePreviewTextEditorLayout {
    static let textContainerInset = NSSize(width: 12, height: 10)
    static let lineFragmentPadding: CGFloat = 0
}

extension SavingTextView {
    /// Builds the File Preview text view configured for large plain-text files.
    ///
    /// File Preview opens files up to `FilePreviewPanel.maximumLoadedTextBytes` (16 MB), which can
    /// be hundreds of thousands of lines. Selection responsiveness on that content is the reason
    /// this configuration is centralized; see `manaflow-ai/cmux#4576`.
    static func makeFilePreviewTextView(
        fontFamily: String = FilePreviewFontFamilySettings.defaultFamily,
        fontSize: CGFloat = CGFloat(FilePreviewFontSizeSettings.defaultPointSize),
        lineHeight: CGFloat = CGFloat(FilePreviewLineHeightSettings.defaultMultiplier)
    ) -> SavingTextView {
        // Build an EXPLICIT TextKit 1 stack so this view is never TextKit 2.
        //
        // A default `NSTextView()` is TextKit 2: selection/hit-testing then runs through
        // `NSTextSelectionNavigation`, whose work is O(N) in line-fragment count, so clicking or
        // drag-selecting in a large document pegs the main thread inside AppKit's modal
        // mouse-tracking loop and freezes the whole app (`manaflow-ai/cmux#4576`, `#5255`).
        //
        // Merely *reading* `.layoutManager` afterward — the previous mitigation — only drops the
        // view to TextKit 2 *compatibility* mode: `textLayoutManager` stays non-nil and the slow
        // selection path remains active (confirmed by live `sample` captures of the hung process).
        // Constructing the view from an `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`
        // stack is the only way to guarantee `textLayoutManager == nil`, i.e. a pure TextKit 1 view
        // whose hit-testing uses `NSLayoutManager` (O(log N) with non-contiguous layout).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Lazy glyph layout so multi-hundred-thousand-line documents still open instantly.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        // No-wrap baseline; `applyFilePreviewWordWrap(_:scrollView:)` flips this live per the
        // `fileEditor.wordWrap` setting.
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = SavingTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.configurePreviewTypography(
            fontFamily: fontFamily,
            defaultFontSize: fontSize,
            lineHeight: lineHeight
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.applyFilePreviewTextEditorInsets()
        return textView
    }
}

extension NSTextView {
    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer.widthTracksTextView = true
            // `widthTracksTextView` keeps the container pinned to the text view
            // width, so wrapping is correct even before the scroll view is laid
            // out. Only snap the frame/container to a real measured width to
            // avoid collapsing to a zero-width container during `makeNSView`,
            // before the clip view has a size; `updateNSView` re-runs once laid
            // out and reflows.
            let visibleWidth = scrollView.contentSize.width
            if visibleWidth > 0 {
                textContainer.size = NSSize(width: visibleWidth, height: .greatestFiniteMagnitude)
                setFrameSize(NSSize(width: visibleWidth, height: frame.height))
            }
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    func applyFilePreviewTextEditorInsets() {
        let targetInset = FilePreviewTextEditorLayout.textContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

final class SavingTextView: NSTextView {
    private static let previewFontZoomShortcutActions: [KeyboardShortcutSettings.Action] = [
        .browserZoomIn,
        .browserZoomOut,
        .browserZoomReset,
    ]

    weak var panel: (any FilePreviewTextEditingPanel)?
    /// Fired after the preview font size changes so highlighting can
    /// re-apply token weights at the new size. Zoom writes a uniform
    /// `.font` across storage; without a forced restyle, keywords stay
    /// regular weight until the text or theme changes.
    var onPreviewFontDidChange: (() -> Void)?
    var appliedFilePreviewTabWidth: Int?
    var appliedFilePreviewTabStopInterval: CGFloat?
    /// Configured baseline size used by the live zoom and reset actions.
    var configuredPreviewFontSize = CGFloat(FilePreviewFontSizeSettings.defaultPointSize)
    /// Current per-editor size after live zoom adjustments.
    var previewFontSize = CGFloat(FilePreviewFontSizeSettings.defaultPointSize)
    /// Whether the user has zoomed this editor away from its configured baseline.
    var hasPreviewFontSizeOverride = false
    /// Normalized configured family used for the current font.
    var previewFontFamily = FilePreviewFontFamilySettings.defaultFamily
    /// Current paragraph line-height multiplier.
    var previewLineHeight = CGFloat(FilePreviewLineHeightSettings.defaultMultiplier)
    /// Whether the representable has supplied its first typography snapshot.
    var hasConfiguredPreviewTypography = false
    private var pendingEditorShortcutChordPrefix: ShortcutStroke?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        installFontMagnificationObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installFontMagnificationObserver()
    }

    deinit {}

    private func installFontMagnificationObserver() {
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyCurrentPreviewFont()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearPendingShortcutChordPrefixes()
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            clearPendingShortcutChordPrefixes()
        }
        return didResign
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if handleEditorShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustPreviewFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(previewFontSize - configuredPreviewFontSize) < 0.0001 {
            _ = setPreviewFontSize(previewFontSize + 5)
        } else {
            _ = resetPreviewFontSize()
        }
    }

    @discardableResult
    func zoomPreviewFontIn() -> Bool {
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomStep)
    }

    @discardableResult
    func zoomPreviewFontOut() -> Bool {
        adjustPreviewFontSize(by: 1 / FilePreviewInteraction.zoomStep)
    }

    @discardableResult
    func resetPreviewFontSize() -> Bool {
        let wasOverridden = hasPreviewFontSizeOverride
        let didChange = setPreviewFontSize(configuredPreviewFontSize, markAsCustomized: false)
        hasPreviewFontSizeOverride = false
        return didChange || wasOverridden
    }

    @discardableResult
    private func adjustPreviewFontSize(by factor: CGFloat) -> Bool {
        setPreviewFontSize(previewFontSize * factor)
    }

    @discardableResult
    private func setPreviewFontSize(_ nextFontSize: CGFloat, markAsCustomized: Bool = true) -> Bool {
        let clamped = CGFloat(FilePreviewFontSizeSettings.clamp(Double(nextFontSize)))
        guard clamped.isFinite else { return false }
        guard abs(clamped - previewFontSize) > 0.0001 else { return false }
        previewFontSize = clamped
        if markAsCustomized {
            hasPreviewFontSizeOverride = true
        }
        applyCurrentPreviewFont()
        return true
    }

    private func clearPendingShortcutChordPrefixes() {
        pendingEditorShortcutChordPrefix = nil
    }

    private func handleEditorShortcut(_ event: NSEvent) -> Bool {
        if hasMarkedText(),
           shortcutRoutingShouldBypassForPrintableOptionText(event: event) {
            clearPendingShortcutChordPrefixes()
            return false
        }

        let candidates = editorShortcutCandidates()
        if let pendingPrefix = pendingEditorShortcutChordPrefix {
            pendingEditorShortcutChordPrefix = nil
            for candidate in candidates {
                guard candidate.shortcut.firstStroke == pendingPrefix,
                      let secondStroke = candidate.shortcut.secondStroke,
                      secondStroke.matches(event: event) else { continue }
                guard candidate.isAllowed(event) else { return false }
                candidate.perform()
                return true
            }
            return false
        }

        for candidate in candidates {
            let shortcut = candidate.shortcut
            if shortcut.secondStroke != nil {
                if shortcut.firstStroke.matches(event: event) {
                    guard candidate.isAllowed(event) else { return false }
                    pendingEditorShortcutChordPrefix = shortcut.firstStroke
                    return true
                }
                continue
            }
            if shortcut.matches(event: event) {
                guard candidate.isAllowed(event) else { return false }
                candidate.perform()
                return true
            }
        }
        return false
    }

    private func editorShortcutCandidates() -> [
        (shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)
    ] {
        var candidates: [(shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)] = []
        let saveShortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        if !saveShortcut.isUnbound {
            candidates.append((saveShortcut, { _ in true }, { [weak self] in self?.panel?.saveTextContent() }))
        }
        for action in Self.previewFontZoomShortcutActions {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { continue }
            candidates.append((
                shortcut,
                { [weak self] event in
                    self?.previewFontZoomShortcutWhenClauseAllows(action: action, event: event) ?? false
                },
                { [weak self] in self?.performPreviewFontZoomShortcutAction(action) }
            ))
        }
        return candidates
    }

    private func previewFontZoomShortcutWhenClauseAllows(
        action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        if window != nil, let appDelegate = AppDelegate.shared {
            return appDelegate.shortcutWhenClauseAllows(action: action, event: event)
        }
        return KeyboardShortcutSettings.effectiveWhenClause(for: action)
            .evaluate(Self.filePreviewTextEditorShortcutContext)
    }

    private static var filePreviewTextEditorShortcutContext: ShortcutContext {
        ShortcutFocusState(
            browser: false,
            markdown: false,
            sidebar: false,
            filePreviewTextEditor: true
        ).context
    }

    private func performPreviewFontZoomShortcutAction(_ action: KeyboardShortcutSettings.Action) {
        switch action {
        case .browserZoomIn:
            _ = zoomPreviewFontIn()
        case .browserZoomOut:
            _ = zoomPreviewFontOut()
        case .browserZoomReset:
            _ = resetPreviewFontSize()
        default:
            break
        }
    }
}

extension FilePreviewPanel {
    func attachTextView(_ textView: NSTextView) {
        self.textView = textView
        focusCoordinator.register(root: textView, primaryResponder: textView, intent: .textEditor)
    }

    @discardableResult
    func zoomTextPreviewIn() -> Bool {
        guard previewMode == .text,
              let textView = textView as? SavingTextView else { return false }
        return textView.zoomPreviewFontIn()
    }

    @discardableResult
    func zoomTextPreviewOut() -> Bool {
        guard previewMode == .text,
              let textView = textView as? SavingTextView else { return false }
        return textView.zoomPreviewFontOut()
    }

    @discardableResult
    func resetTextPreviewZoom() -> Bool {
        guard previewMode == .text,
              let textView = textView as? SavingTextView else { return false }
        return textView.resetPreviewFontSize()
    }
}
