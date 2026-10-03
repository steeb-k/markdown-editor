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
/// Main thread only (`@MainActor`): WebKit calls its delegates there, the analysis queue's answers
/// arrive there.
@MainActor
public final class PreviewController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public let webView: PreviewWebView
    public let schemeHandler = PreviewSchemeHandler()
    private weak var session: EditorSession?

    // State, main thread.
    public private(set) var isVisible = false
    private var isLoaded = false
    private var isLoading = false
    private var isInitialLoad = false
    /// The app's own load of the page has been let through (once per load: a refresh or a frame
    /// the document's HTML asks for is not).
    private var initialNavigationAllowed = false
    private var stale = true
    private var inFlight = false
    private var timer: Timer?
    private var jsInFlight = 0
    private var lineTable: (seq: Int, table: LineTable)?
    /// The sizes of the pictures the page refers to, read from their files' headers (cached).
    let pictureSizes = PictureSizes()

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
    /// How long handing the last update to the page held the main thread (the call itself).
    public private(set) var lastApplyMainThreadTime: TimeInterval = 0
    private var lastEditTime = CFAbsoluteTimeGetCurrent()
    /// Called on the main thread after every update of the page.
    public var onApplied: (() -> Void)?
    /// What happened to the last navigation the user asked for (tests and the UI script).
    public private(set) var lastLinkAction: LinkAction?
    /// In notes mode a click on a link to a note (a wikilink as the page spells it) asks the window to open
    /// the note through the library; otherwise such a link opens the file as any other.
    var opensNotes = false
    var onOpenNote: ((_ target: String, _ fragment: String?) -> Void)?

    // Chrome (title bar and toolbar) the page keeps clear of, like the editor's content insets.
    private var chrome = (top: CGFloat(0), bottom: CGFloat(0))

    // Scroll sync.
    weak var scrollView: NSScrollView?
    private var lastEditorOffset: CGFloat?
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
        schemeHandler.documentURL = { [weak session] in session?.documentURL() }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Preview")
        applyBackground()
    }

    deinit {
        // Swift may run this on any thread; WebKit is main-thread only.
        let web = webView, timer = timer, observers = observers
        let cleanup: @MainActor () -> Void = {
            timer?.invalidate()
            observers.forEach(NotificationCenter.default.removeObserver)
            web.configuration.userContentController.removeAllUserScripts()
            web.configuration.userContentController.removeScriptMessageHandler(forName: PreviewScripts.handlerName, contentWorld: PreviewScripts.world)
        }
        if Thread.isMainThread { MainActor.assumeIsolated(cleanup) } else { DispatchQueue.main.async { MainActor.assumeIsolated(cleanup) } }
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
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer = nil; self?.startRender() }
        }
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
        let documentURL = session.documentURL()
        let sizes = pictureSizes
        let started = CFAbsoluteTimeGetCurrent()
        // The body the page holds: the new one is sent as a patch against it, worked out here on
        // the analysis queue rather than on the main thread.
        let base = first ? nil : pageBody
        session.coordinator.async({ doc -> (String, BodyPatch?) in
            // The pictures' sizes go into the page, so it reserves their room before they load.
            let html = doc.renderHtml(options: Self.withPictureSizes(options, sizes: sizes, doc: doc, documentURL: documentURL))
            return (html, base.flatMap { BodyPatch.make(from: $0, to: html) })
        }) { [weak self] rendered, processedSeq in
            guard let self else { return }
            let (html, patch) = rendered
            if base == nil { rendersWithoutBase += 1 } else if patch == nil { rendersWithoutPatch += 1 }
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
            apply(html, patch: patch, standalone: first, seq: processedSeq)
            if stale, isVisible, timer == nil { renderSoon(delay: ScrollSync.debounce(forLength: session.storage.length)) }
        }
    }

    func renderOptions(standalone: Bool) -> RenderOptions {
        RenderOptions(sourceLines: true, standalone: standalone, sanitize: false, highlight: true,
                      fallbackTitle: "Untitled", style: standalone ? previewStyle() : nil)
    }

    /// `options` with the sizes of the pictures `doc` refers to (on the analysis queue, where `doc`
    /// lives): what every render for the page is made with, and what a check of the page must use.
    static func withPictureSizes(_ options: RenderOptions, sizes: PictureSizes, doc: Document, documentURL: URL?) -> RenderOptions {
        var options = options
        options.imageSizes = sizes.sizes(for: Set(doc.images().map(\.destination)), documentURL: documentURL)
        return options
    }

    /// The editor's theme and type, as the preview's stylesheet wants them.
    func previewStyle() -> PreviewStyle {
        let appearance = session?.appearance ?? EditorAppearance(settings: .shared, appearance: nil)
        return PreviewStyle(theme: appearance.theme, typography: PreviewTypography.make(from: appearance))
    }

    private func apply(_ html: String, patch: BodyPatch? = nil, standalone: Bool, seq: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let total = lines(forSeq: seq).lineCount
        if standalone {
            pageBody = nil
            // The first time: the page with an empty body, loaded with the app's scheme as its
            // address; the body follows the way every later one does (`replaceBody`), so its
            // pictures and links are routed before anything in it loads.
            isLoading = true
            isLoaded = false
            isInitialLoad = true
            initialNavigationAllowed = false
            appliedCSS = previewCSS()
            appliedFonts = PreviewTypography.fontFaceCSS(for: session?.appearance)
            let parts = Self.split(page: html)
            lastBodyHTML = parts.body
            pendingBody = parts.body
            applyBackground()
            webView.loadHTMLString(parts.shell, baseURL: PreviewURL.base)
            pendingTotalLines = total
            return
        }
        lastBodyHTML = html
        jsInFlight += 1
        defer { lastApplyMainThreadTime = CFAbsoluteTimeGetCurrent() - t0 }
        let script: String
        let arguments: [String: Any]
        if let patch, pageBody != nil {
            script = "return __md.patchBody(start, oldEnd, insert, delta, total, oldLength, newLength);"
            arguments = ["start": patch.start, "oldEnd": patch.oldEnd, "insert": patch.insert, "delta": patch.lineDelta, "total": total,
                         "oldLength": patch.oldLength, "newLength": patch.newLength]
            patchesSent += 1
        } else {
            script = "return __md.replaceBody(html, total);"
            arguments = ["html": html, "total": total]
        }
        pageBody = nil
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: PreviewScripts.world) { [weak self] result in
            guard let self else { return }
            jsInFlight -= 1
            if case .failure = result { stale = true; renderSoon(delay: 0.2); return }
            if case .success(let value) = result, (value as? Bool) != true {
                // The page did not hold what the patch was made from: the whole body, then.
                patchesRefused += 1
                apply(html, standalone: false, seq: seq)
                return
            }
            pageBody = html
            applied += 1
            lastApplyTime = CFAbsoluteTimeGetCurrent() - t0
            lastLatency = CFAbsoluteTimeGetCurrent() - lastEditTime
            syncAfterUpdate(afterEdit: true)
            onApplied?()
        }
    }

    private var pendingTotalLines = 0
    private var pendingBody = ""
    /// The body the page is known to hold (nil while an update is on its way or after a failure).
    private var pageBody: String?
    /// Instrumentation: updates sent as patches, and patches the page could not apply.
    public private(set) var patchesSent = 0
    public private(set) var patchesRefused = 0
    public private(set) var rendersWithoutBase = 0
    public private(set) var rendersWithoutPatch = 0
    private var appliedCSS = ""
    private var appliedFonts = ""

    /// A standalone page as the page without its body (`<main>` empty), and the body (what the
    /// core's non-standalone render gives).
    static func split(page: String) -> (shell: String, body: String) {
        guard let start = page.range(of: "<main class=\"md\" id=\"md\">\n"), let end = page.range(of: "</main>\n</body>", options: .backwards),
              start.upperBound <= end.lowerBound else { return (page, "") }
        return (String(page[..<start.upperBound]) + String(page[end.lowerBound...]), String(page[start.upperBound..<end.lowerBound]))
    }

    /// The part of a standalone page's HTML that the core's non-standalone render would give.
    static func body(of page: String) -> String { split(page: page).body }

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
        let body = pendingBody
        pendingBody = ""
        webView.callAsyncJavaScript("__md.prepare(total); __md.setFonts(fonts); __md.setChrome(top, bottom); __md.replaceBody(body, total); return true;",
                                    arguments: ["total": pendingTotalLines, "fonts": fonts, "top": chrome.top, "bottom": chrome.bottom, "body": body],
                                    in: nil, in: PreviewScripts.world) { [weak self] result in
            guard let self else { return }
            jsInFlight -= 1
            if case .success = result { pageBody = body }
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
            isInitialLoad: isInitialLoad && !initialNavigationAllowed && navigationAction.navigationType == .other,
            documentURL: session?.documentURL(), notes: opensNotes)
        if action == .allow { initialNavigationAllowed = true }
        perform(action)
        decisionHandler(action == .allow ? .allow : .cancel)
    }

    /// A link that wants a new window: the same decision, never a window.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let action = LinkPolicy.decide(url: navigationAction.request.url, isLinkActivation: true, isMainFrame: true,
                                       isInitialLoad: false, documentURL: session?.documentURL(), notes: opensNotes)
        perform(action)
        return nil
    }

    /// Carries a decision out.
    func perform(_ action: LinkAction) {
        lastLinkAction = action
        switch action {
        case .allow, .ignore: break
        case .open(let url): LinkOpener.open(url)
        case .openNote(let target, let fragment): onOpenNote?(target, fragment)
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
        ) { [weak self] _ in MainActor.assumeIsolated { self?.editorScrolled() } })
    }

    private var syncs: Bool { isVisible && isLoaded && (session?.layout == .split) }

    private func editorScrolled() {
        guard syncs, let clip = scrollView?.contentView else { return }
        // The editor's own notifications for a scroll the preview asked for (AppKit sends more
        // than one): recognised by where they leave the editor, not by when they come, so a
        // scroll the user makes straight after is never taken for one.
        if let last = lastEditorOffset, abs(clip.bounds.minY - last) < 1 { return }
        // Nor a move made while the editor is being aimed: scrolling it lays out the new screenful, which corrects the
        // estimated heights above it, and AppKit moves the clip view again (inside the same call) to keep the drawn
        // text in place: in preview.json by 538 pt, once the text view's origin stopped being -104. That move is not the
        // reader's; pushed to the page, it sent the page back 18 lines, the page reported that, and the editor followed
        // it there. The second aim (`scrollEditor`) puts the editor right.
        if aiming { return }
        lastEditorOffset = nil
        pushEditorScroll()
    }

    /// Whether the editor is scrolled as far down as it goes.
    private var editorIsAtEnd: Bool {
        guard let sv = scrollView else { return false }
        return Self.isAtEnd(sv)
    }

    /// Whether `scrollView` is scrolled as far down as AppKit lets it go (asked of the clip view:
    /// the content insets make the arithmetic easy to get wrong).
    static func isAtEnd(_ scrollView: NSScrollView) -> Bool {
        let clip = scrollView.contentView
        let lowest = clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: 1e9, width: clip.bounds.width, height: clip.bounds.height)).minY
        let highest = clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: -1e9, width: clip.bounds.width, height: clip.bounds.height)).minY
        return lowest > highest + 1 && clip.bounds.minY >= lowest - 1
    }

    /// Moves the preview to where the editor is. The ends are the ends: the editor at its last
    /// screenful puts the preview at its last (each view's last screenful starts at a different
    /// line, so interpolating would leave one short of its end).
    func pushEditorScroll() {
        guard syncs else { return }
        if scrollInFlight { scrollDirty = true; return }
        guard var position = editorReadingPosition() else { return }
        if editorIsAtEnd { position = Double(currentLineTable().lineCount + 1) }
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
    private func syncAfterUpdate(afterEdit: Bool = false) {
        guard syncs, let session, var position = editorReadingPosition() else { return }
        if editorIsAtEnd { position = Double(currentLineTable().lineCount + 1) }
        var caretLine: Int?
        // The block being typed in stays on screen: after an edit, and only when the caret is on
        // the editor's screen (a theme change, or a caret the user scrolled away from, does not
        // pull the preview off the editor's place).
        if afterEdit, let tv = session.textView, tv.window?.firstResponder === tv {
            let caret = tv.selectedRange().location
            let visible = tv.visibleCharacterRange()
            if caret >= visible.location, caret <= NSMaxRange(visible) {
                caretLine = lines(forSeq: session.coordinator.latestSeq).line(at: caret)
            }
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
        if receivedScrolls.count > 200 { receivedScrolls.removeFirst(100) }
        scrollEditor(toPosition: line, atEnd: (body["atEnd"] as? Bool) ?? false)
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
        // The top of what the reader sees: under the title bar, not under the room focus mode adds
        // above the text for centring (that would pair the preview's top with the editor's middle).
        let y = sv.contentView.bounds.minY + sv.editorBaseInsetTop - origin.y
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
    func scrollEditor(toPosition position: Double, atEnd: Bool = false) {
        scrollEditorOnce(toPosition: position, atEnd: atEnd)
        // The editor lays out lazily: the heights above the target were partly estimates, and
        // drawing the new screenful lays them out. Aim again once that has happened.
        guard !atEnd else { return }
        pendingEditorPosition = position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingEditorPosition == position else { return }
                self.pendingEditorPosition = nil
                self.scrollEditorOnce(toPosition: position, atEnd: false)
            }
        }
    }

    private var pendingEditorPosition: Double?
    /// The editor is being scrolled to where the page is (see `editorScrolled`).
    private var aiming = false

    private func scrollEditorOnce(toPosition position: Double, atEnd: Bool) {
        guard syncs, let session, let tv = session.textView, let sv = scrollView ?? tv.enclosingScrollView,
              let tc = tv.textContainer else { return }
        let lm = session.layoutManager
        let table = currentLineTable()
        let length = session.storage.length
        let location = min(table.location(at: position), max(0, length - 1))
        var y: CGFloat = 0
        if atEnd {
            // The preview at its end: the editor at its end. The editor lays out lazily and its
            // height is an estimate until the end is laid out: the text view's own scroll to the
            // end (what Command-Down does, without moving the selection) lays it out first.
            if length > 0 {
                lm.ensureLayout(forCharacterRange: NSRange(location: max(0, length - 1), length: 1))
                lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: lm.usedRect(for: tc).maxY - 2 * sv.contentView.bounds.height,
                                                        width: tc.size.width, height: 2 * sv.contentView.bounds.height), in: tc)
                tv.sizeToFit()
            }
            tv.scrollToEndOfDocument(nil)
            lastEditorOffset = sv.contentView.bounds.minY
            lastEditorScrollTrace = "position end target \(sv.contentView.bounds.minY)"
            return
        } else if position <= 0.0001 {
            // The top is the top (not the first line's top, which sits below the editor's margin).
            y = -tv.textContainerOrigin.y
        } else if length > 0 {
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
        // As far as the clip view allows (it knows what the content insets do to the range). The
        // position goes to the top of what the reader sees (see `editorReadingPosition`).
        let wanted = y + tv.textContainerOrigin.y - sv.editorBaseInsetTop
        let target = Double(clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: wanted, width: clip.bounds.width, height: clip.bounds.height)).minY)
        lastEditorScrollTrace = "position \(position) target \(target) was \(clip.bounds.minY) y \(y)"
        guard abs(clip.bounds.minY - CGFloat(target)) >= 1 else { return }
        lastEditorOffset = CGFloat(target)
        aiming = true
        defer { aiming = false }
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
