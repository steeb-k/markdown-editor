import AppKit
import WebKit
import MarkdownCore

/// The preview's web view. Page JavaScript is off for everything a document can put in it; the
/// app's own script (see `PreviewScripts`) runs in a content world of its own.
public final class PreviewWebView: WKWebView {
    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // A document is not a web page: no Reload, Back, Forward, Open Link in New Window...
        let keep: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopyImage",
                                 "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSpeechMenu", "WKMenuItemIdentifierTranslate"]
        for item in menu.items.reversed() {
            if let id = item.identifier?.rawValue, !keep.contains(id) { menu.removeItem(item) }
        }
    }
}

/// What the preview shows for one window: the document rendered by the core (on the analysis
/// queue, debounced, never more than one render in flight), applied to the page in place so the
/// scroll position survives, kept in step with the editor's scrolling, themed like the editor.
public final class PreviewController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public let webView: PreviewWebView
    public let schemeHandler = PreviewSchemeHandler()
    private weak var session: EditorSession?

    // State, main thread.
    public private(set) var isVisible = false
    private var isLoaded = false
    private var isLoading = false
    private var isInitialLoad = false
    private var stale = true
    private var inFlight = false
    private var timer: Timer?
    private var jsInFlight = 0
    private var lineTable: (seq: Int, table: LineTable)?

    // Instrumentation.
    /// Renders started (the core ran), applied to the page, and thrown away because a newer text had arrived.
    public private(set) var renders = 0
    public private(set) var applied = 0
    public private(set) var superseded = 0
    /// The body of the last HTML applied (what the core rendered, with `data-line`).
    public private(set) var lastBodyHTML = ""
    /// Seconds from the last edit to the page showing it, and how long the core and the page took.
    public private(set) var lastLatency: TimeInterval = 0
    public private(set) var lastRenderTime: TimeInterval = 0
    public private(set) var lastApplyTime: TimeInterval = 0
    private var lastEditTime = CFAbsoluteTimeGetCurrent()
    /// Called on the main thread after every update of the page.
    public var onApplied: (() -> Void)?
    /// What happened to the last navigation the user asked for (tests and the UI script).
    public private(set) var lastLinkAction: LinkAction?

    // Chrome (title bar and toolbar) the page keeps clear of, like the editor's content insets.
    private var chrome = (top: CGFloat(0), bottom: CGFloat(0))

    // Scroll sync.
    weak var scrollView: NSScrollView?
    private var lastEditorOffset: CGFloat?
    private var ignoreEditorScrollsUntil: CFAbsoluteTime = 0
    private var scrollInFlight = false
    private var scrollDirty = false
    private var observers: [NSObjectProtocol] = []

    public init(session: EditorSession) {
        self.session = session
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = false
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.scheme)
        webView = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: config)
        super.init()
        let weakHandler = WeakScriptHandler(self)
        config.userContentController.addUserScript(WKUserScript(source: PreviewScripts.source, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: PreviewScripts.world))
        config.userContentController.add(weakHandler, contentWorld: PreviewScripts.world, name: PreviewScripts.handlerName)
        schemeHandler.documentFolder = { [weak session] in PreviewURL.folder(of: session?.documentURL()) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Preview")
        applyBackground()
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PreviewScripts.handlerName, contentWorld: PreviewScripts.world)
    }

    /// Stops listening and drops the page (the window closed).
    public func tearDown() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    // MARK: visibility and scheduling

    /// The preview is on screen (the layout shows it). Nothing is rendered while it is not; what
    /// changed meanwhile is rendered when it comes back.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if !isLoaded || stale { renderSoon(delay: 0) }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The text changed (any edit, a load, a revert).
    public func textChanged() {
        stale = true
        lastEditTime = CFAbsoluteTimeGetCurrent()
        lineTable = nil
        guard isVisible else { return }
        renderSoon(delay: ScrollSync.debounce(forLength: session?.storage.length ?? 0))
    }

    private func renderSoon(delay: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.timer = nil; self?.startRender() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// True when nothing is owed to the page: no change waiting, no render or page call in flight.
    public var isSettled: Bool {
        (!isVisible || (!stale && isLoaded)) && !inFlight && !isLoading && jsInFlight == 0 && timer == nil
    }

    /// Spins the run loop until the page shows the current text (tests, the UI script).
    @discardableResult
    public func waitUntilSettled(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if isSettled { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return isSettled
    }

    // MARK: rendering

    private func startRender() {
        guard isVisible, stale, !isLoading, let session else { return }
        if inFlight { return } // the completion looks again
        inFlight = true
        stale = false
        renders += 1
        let first = !isLoaded
        let options = renderOptions(standalone: first)
        let started = CFAbsoluteTimeGetCurrent()
        session.coordinator.async({ doc in doc.renderHtml(options: options) }) { [weak self] html, processedSeq in
            guard let self else { return }
            inFlight = false
            lastRenderTime = CFAbsoluteTimeGetCurrent() - started
            guard let session = self.session else { return }
            // A newer text has been typed since: this render is out of date; the next one covers it.
            if processedSeq != session.coordinator.latestSeq {
                superseded += 1
                stale = true
                if isVisible { renderSoon(delay: ScrollSync.debounce(forLength: session.storage.length)) }
                return
            }
            if !isVisible { stale = true; return }
            apply(html, standalone: first, seq: processedSeq)
            if stale, isVisible, timer == nil { renderSoon(delay: ScrollSync.debounce(forLength: session.storage.length)) }
        }
    }

    func renderOptions(standalone: Bool) -> RenderOptions {
        RenderOptions(sourceLines: true, standalone: standalone, sanitize: false, highlight: true,
                      fallbackTitle: "Untitled", style: standalone ? previewStyle() : nil)
    }

    /// The editor's theme and type, as the preview's stylesheet wants them.
    func previewStyle() -> PreviewStyle {
        let appearance = session?.appearance ?? EditorAppearance(settings: .shared, appearance: nil)
        return PreviewStyle(theme: appearance.theme, typography: PreviewTypography.make(from: appearance))
    }

    private func apply(_ html: String, standalone: Bool, seq: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let total = lines(forSeq: seq).lineCount
        if standalone {
            // The first time: a complete page, loaded with the app's scheme as its address.
            isLoading = true
            isLoaded = false
            isInitialLoad = true
            appliedCSS = previewCSS()
            appliedFonts = PreviewTypography.fontFaceCSS(for: session?.appearance)
            lastBodyHTML = Self.body(of: html)
            applyBackground()
            webView.loadHTMLString(html, baseURL: PreviewURL.base)
            pendingTotalLines = total
            return
        }
        lastBodyHTML = html
        jsInFlight += 1
        webView.callAsyncJavaScript("return __md.replaceBody(html, total);", arguments: ["html": html, "total": total],
                                    in: nil, in: PreviewScripts.world) { [weak self] result in
            guard let self else { return }
            jsInFlight -= 1
            if case .failure = result { stale = true; renderSoon(delay: 0.2); return }
            applied += 1
            lastApplyTime = CFAbsoluteTimeGetCurrent() - t0
            lastLatency = CFAbsoluteTimeGetCurrent() - lastEditTime
            syncAfterUpdate()
            onApplied?()
        }
    }

    private var pendingTotalLines = 0
    private var appliedCSS = ""
    private var appliedFonts = ""

    /// The part of a standalone page's HTML that the core's non-standalone render would give.
    static func body(of page: String) -> String {
        guard let start = page.range(of: "<main class=\"md\" id=\"md\">\n"), let end = page.range(of: "</main>\n</body>", options: .backwards) else { return page }
        return String(page[start.upperBound..<end.lowerBound])
    }

    private func lines(forSeq seq: Int) -> LineTable {
        if let l = lineTable, l.seq == seq { return l.table }
        let table = LineTable((session?.storage.string ?? "") as NSString)
        lineTable = (seq, table)
        return table
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isInitialLoad else { return }
        isInitialLoad = false
        isLoaded = true
        isLoading = false
        jsInFlight += 1
        let fonts = PreviewTypography.fontFaceCSS(for: session?.appearance)
        webView.callAsyncJavaScript("__md.prepare(total); __md.setFonts(fonts); __md.setChrome(top, bottom); return true;",
                                    arguments: ["total": pendingTotalLines, "fonts": fonts, "top": chrome.top, "bottom": chrome.bottom],
                                    in: nil, in: PreviewScripts.world) { [weak self] _ in
            guard let self else { return }
            jsInFlight -= 1
            applied += 1
            lastApplyTime = 0
            lastLatency = CFAbsoluteTimeGetCurrent() - lastEditTime
            syncAfterUpdate()
            onApplied?()
            if stale, isVisible { renderSoon(delay: 0.05) }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed() }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed() }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadFailed() }

    private func loadFailed() {
        isLoaded = false
        isLoading = false
        isInitialLoad = false
        stale = true
        if isVisible { renderSoon(delay: 0.3) }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let action = LinkPolicy.decide(
            url: navigationAction.request.url,
            isLinkActivation: navigationAction.navigationType == .linkActivated,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
            isInitialLoad: isInitialLoad && navigationAction.navigationType == .other,
            documentFolder: PreviewURL.folder(of: session?.documentURL()))
        perform(action)
        decisionHandler(action == .allow ? .allow : .cancel)
    }

    /// A link that wants a new window: the same decision, never a window.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let action = LinkPolicy.decide(url: navigationAction.request.url, isLinkActivation: true, isMainFrame: true,
                                       isInitialLoad: false, documentFolder: PreviewURL.folder(of: session?.documentURL()))
        perform(action)
        return nil
    }

    /// Carries a decision out.
    func perform(_ action: LinkAction) {
        lastLinkAction = action
        switch action {
        case .allow, .ignore: break
        case .open(let url): LinkOpener.open(url)
        case .scrollToFragment(let id):
            webView.callAsyncJavaScript("return __md.scrollToId(id);", arguments: ["id": id], in: nil, in: PreviewScripts.world) { _ in }
        }
    }

    // MARK: appearance

    /// Theme, fonts or size changed: the page's stylesheet follows, in place.
    public func appearanceChanged() {
        applyBackground()
        guard isLoaded else { return }
        let css = previewCSS()
        let fonts = PreviewTypography.fontFaceCSS(for: session?.appearance)
        // The window asks whenever anything about the editor's look may have changed.
        guard css != appliedCSS || fonts != appliedFonts else { return }
        appliedCSS = css
        appliedFonts = fonts
        jsInFlight += 1
        webView.callAsyncJavaScript("__md.setFonts(fonts); __md.setStyle(css); return true;", arguments: ["css": css, "fonts": fonts],
                                    in: nil, in: PreviewScripts.world) { [weak self] _ in
            guard let self else { return }
            jsInFlight -= 1
            syncAfterUpdate()
            onApplied?()
        }
    }

    func previewCSS() -> String {
        let style = previewStyle()
        return previewCss(theme: style.theme, typography: style.typography)
    }

    private func applyBackground() {
        if let p = session?.appearance.palette { webView.underPageBackgroundColor = p.background }
    }

    /// The title bar and the toolbar cover this much of the page's top and bottom.
    public func setChrome(top: CGFloat, bottom: CGFloat) {
        guard chrome.top != top || chrome.bottom != bottom else { return }
        chrome = (top, bottom)
        guard isLoaded else { return }
        jsInFlight += 1
        webView.callAsyncJavaScript("return __md.setChrome(top, bottom);", arguments: ["top": top, "bottom": bottom],
                                    in: nil, in: PreviewScripts.world) { [weak self] _ in self?.jsInFlight -= 1 }
    }

    // MARK: scroll sync

    /// Starts following the editor's scrolling (called once the editor's scroll view exists).
    func observeEditor(_ scroll: NSScrollView) {
        scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in self?.editorScrolled() })
    }

    private var syncs: Bool { isVisible && isLoaded && (session?.layout == .split) }

    private func editorScrolled() {
        guard syncs, let clip = scrollView?.contentView else { return }
        // The editor's own notifications for a scroll the preview asked for (AppKit sends more than one).
        if CFAbsoluteTimeGetCurrent() < ignoreEditorScrollsUntil { return }
        if let last = lastEditorOffset, abs(clip.bounds.minY - last) < 1 { lastEditorOffset = nil; return }
        lastEditorOffset = nil
        pushEditorScroll()
    }

    /// Moves the preview to where the editor is.
    func pushEditorScroll() {
        guard syncs else { return }
        if scrollInFlight { scrollDirty = true; return }
        guard let position = editorReadingPosition() else { return }
        scrollInFlight = true
        jsInFlight += 1
        webView.callAsyncJavaScript("return __md.scrollToLine(line, false);", arguments: ["line": position],
                                    in: nil, in: PreviewScripts.world) { [weak self] _ in
            guard let self else { return }
            jsInFlight -= 1
            scrollInFlight = false
            if scrollDirty { scrollDirty = false; pushEditorScroll() }
        }
    }

    /// After the page changed under the editor: put it back where the editor is (only when it has
    /// drifted, so typing does not make it jitter) and keep the block being typed in on screen.
    private func syncAfterUpdate() {
        guard syncs, let session, let position = editorReadingPosition() else { return }
        var caretLine: Int?
        if let tv = session.textView, tv.window?.firstResponder === tv {
            caretLine = lines(forSeq: session.coordinator.latestSeq).line(at: tv.selectedRange().location)
        }
        jsInFlight += 1
        webView.callAsyncJavaScript("__md.scrollToLine(line, true); if (caret !== null) { __md.revealLine(caret); } return true;",
                                    arguments: ["line": position, "caret": caretLine as Any? ?? NSNull()],
                                    in: nil, in: PreviewScripts.world) { [weak self] _ in self?.jsInFlight -= 1 }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "scroll",
              let line = (body["line"] as? NSNumber)?.doubleValue else { return }
        receivedScrolls.append(line)
        scrollEditor(toPosition: line)
    }

    /// Instrumentation: the source positions the page reported (user scrolls of the preview).
    public private(set) var receivedScrolls: [Double] = []
    public private(set) var lastEditorScrollTrace = ""

    /// The source position (line and fraction) at the top of the editor's visible text.
    func editorReadingPosition() -> Double? {
        guard let session, let tv = session.textView, let sv = scrollView ?? tv.enclosingScrollView,
              let tc = tv.textContainer else { return nil }
        let lm = session.layoutManager
        let table = currentLineTable()
        let origin = tv.textContainerOrigin
        let y = sv.contentView.bounds.minY + sv.contentInsets.top - origin.y
        if y <= 0 || session.storage.length == 0 { return 0 }
        lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: y, width: tc.size.width, height: 40), in: tc)
        let glyph = lm.glyphIndex(for: NSPoint(x: tc.size.width / 2, y: y), in: tc, fractionOfDistanceThroughGlyph: nil)
        guard glyph < lm.numberOfGlyphs else { return table.position(at: session.storage.length) }
        var glyphRange = NSRange()
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
        let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let start = table.position(at: chars.location)
        let end = table.position(at: min(NSMaxRange(chars), session.storage.length))
        let within = fragment.height > 0 ? min(1, max(0, (y - fragment.minY) / fragment.height)) : 0
        return start + within * max(0, end - start)
    }

    private func currentLineTable() -> LineTable {
        guard let session else { return LineTable("" as NSString) }
        let seq = session.coordinator.latestSeq
        return lines(forSeq: seq)
    }

    /// Scrolls the editor so that source position `position` is at its top (a scroll the user did
    /// not make: its echo is ignored).
    func scrollEditor(toPosition position: Double) {
        guard syncs, let session, let tv = session.textView, let sv = scrollView ?? tv.enclosingScrollView,
              let tc = tv.textContainer else { return }
        let lm = session.layoutManager
        let table = currentLineTable()
        let length = session.storage.length
        let location = min(table.location(at: position), max(0, length - 1))
        var y: CGFloat = 0
        if length > 0 {
            lm.ensureLayout(forCharacterRange: NSRange(location: location, length: min(1, length - location)))
            let glyph = lm.glyphIndexForCharacter(at: location)
            var glyphRange = NSRange()
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let start = table.position(at: chars.location)
            let end = table.position(at: min(NSMaxRange(chars), length))
            let t = end > start ? min(1, max(0, (position - start) / (end - start))) : 0
            y = fragment.minY + t * fragment.height
            _ = tc
        }
        let clip = sv.contentView
        let insets = sv.contentInsets
        let target = ScrollSync.clamp(Double(y + tv.textContainerOrigin.y - insets.top), contentHeight: Double(tv.frame.height + insets.bottom),
                                      viewportHeight: Double(clip.bounds.height), minimum: Double(-insets.top))
        lastEditorScrollTrace = "position \(position) target \(target) was \(clip.bounds.minY) y \(y)"
        guard abs(clip.bounds.minY - CGFloat(target)) >= 1 else { return }
        lastEditorOffset = CGFloat(target)
        ignoreEditorScrollsUntil = CFAbsoluteTimeGetCurrent() + 0.1
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: CGFloat(target)))
        sv.reflectScrolledClipView(clip)
    }

    // MARK: tests and the UI script

    /// The page's scroll offset and size (points), asked of the page.
    func metrics(_ completion: @escaping ([String: Double]?) -> Void) {
        guard isLoaded else { completion(nil); return }
        webView.callAsyncJavaScript("return __md.metrics();", arguments: [:], in: nil, in: PreviewScripts.world) { result in
            if case .success(let v) = result, let d = v as? [String: Any] {
                completion(d.compactMapValues { ($0 as? NSNumber)?.doubleValue })
            } else { completion(nil) }
        }
    }

    /// Runs `script` (a function body) in the app's world and returns its result, spinning the run loop.
    func evaluateSync(_ script: String, arguments: [String: Any] = [:], timeout: TimeInterval = 10) -> Any? {
        var done = false
        var value: Any?
        jsInFlight += 1
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: PreviewScripts.world) { [weak self] result in
            self?.jsInFlight -= 1
            if case .success(let v) = result { value = v }
            done = true
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done, Date() < deadline { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
        return value
    }

    /// The page's own state, for tests: the rendered body as the page holds it, and the scroll position.
    public var scrollTopForTests: Double { (evaluateSync("return __md.scrollTop();") as? NSNumber)?.doubleValue ?? 0 }
}

/// Breaks the cycle between the web view's content controller and the preview controller.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

// MARK: - type and fonts

/// The editor's type, in the preview's terms.
enum PreviewTypography {
    private static let sansFallback = "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
    private static let serifFallback = "ui-serif, \"New York\", Georgia, serif"
    private static let monoFallback = "ui-monospace, SFMono-Regular, Menlo, monospace"

    /// The CSS family names of the bundled faces (declared with `@font-face` through the scheme handler).
    static let bundledFamilies: [FontChoice: String] = [
        .iaMono: "Bundled Mono", .iaDuo: "Bundled Duo", .iaQuattro: "Bundled Quattro",
    ]

    static func make(from a: EditorAppearance) -> Typography {
        let bodyIsMono = FontSet.isMonospaced(a.fonts.body)
        let body = stack(for: a.fonts.body, monospaced: bodyIsMono)
        // A monospaced body is also the code font (same stack: the stylesheet then sets code at the same size).
        let mono = bodyIsMono ? body : stack(for: a.fonts.mono, monospaced: true)
        return Typography(fontFamily: body, monoFamily: mono, fontSizePx: Double(a.fonts.size),
                          lineHeight: Double(a.lineHeight), measureCh: Double(a.maxCharacters))
    }

    /// A font as a CSS family stack: the bundled faces by the names declared for them, installed
    /// fonts by their own family name, the system fonts by their generic names; then a fallback of
    /// the same kind.
    private static func stack(for font: NSFont, monospaced: Bool) -> String {
        let family = font.familyName ?? ""
        // The font class in the descriptor's symbolic traits: 1...5 are the serif classes.
        let serif = (1...5).contains(font.fontDescriptor.symbolicTraits.rawValue >> 28) || family.contains("New York")
        let fallback = monospaced ? monoFallback : (serif ? serifFallback : sansFallback)
        if font.fontName.hasPrefix("iAWriter"),
           let name = bundledFamilies.values.first(where: { font.fontName.hasPrefix($0.replacingOccurrences(of: " ", with: "")) }) {
            return "\"\(name)\", \(fallback)"
        }
        if family.isEmpty || family.hasPrefix(".") || family == "System Font" { return fallback }
        return "\"" + family.replacingOccurrences(of: "\"", with: "") + "\", " + fallback
    }

    /// `@font-face` rules for the bundled faces the appearance uses (a web view's content process
    /// cannot see fonts registered in the app, so the files are served through the scheme handler).
    static func fontFaceCSS(for appearance: EditorAppearance?) -> String {
        guard let a = appearance, FontStore.bundledFontsAvailable else { return "" }
        var out = ""
        var seen = Set<String>()
        for font in [a.fonts.body, a.fonts.mono] where font.fontName.hasPrefix("iAWriter") {
            guard let dash = font.fontName.firstIndex(of: "-") else { continue }
            let prefix = String(font.fontName[..<dash])   // iAWriterQuattroS
            guard seen.insert(prefix).inserted, let cssFamily = bundledFamilies.values.first(where: { $0.replacingOccurrences(of: " ", with: "") == prefix }) else { continue }
            for (style, weight, italic) in [("Regular", 400, false), ("Italic", 400, true), ("Bold", 700, false), ("BoldItalic", 700, true)] {
                out += "@font-face { font-family: \"\(cssFamily)\"; font-weight: \(weight); font-style: \(italic ? "italic" : "normal"); "
                out += "src: url(\"mdoc://doc/font/\(prefix)-\(style).ttf\") format(\"truetype\"); }\n"
            }
        }
        return out
    }
}
