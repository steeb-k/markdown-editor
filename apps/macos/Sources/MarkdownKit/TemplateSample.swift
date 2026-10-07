import AppKit
import SwiftUI
import WebKit
import MarkdownCore

/// The page the Templates window shows: `Template Sample.md` (every element kind once) rendered by the core as a standalone
/// page, in the template's stylesheet. A change of template or of one field swaps the page's style element in place
/// (`__md.setStyle`): the page is loaded once and never reloaded, so the scroll position stays and nothing flashes.
///
/// The page's script reports a click as `{"type": "templateClick", "kind": key}` (the innermost element with a kind, see
/// `PreviewScripts`), which is what makes the inspector follow the click. Main thread.
@MainActor
final class TemplateSampleController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    let schemeHandler = PreviewSchemeHandler()
    /// A click on the page named this kind (`h1`, `code_block`).
    var onClick: ((String) -> Void)?

    private var isLoaded = false
    private var jsInFlight = 0
    private var wantedCSS = ""
    private var wantedFonts = ""
    private var wantedOutline: String?
    private var wantedBackground: NSColor?
    private var appliedCSS: String?
    private var appliedFonts: String?
    private var appliedOutline: String?
    private var outlineApplied = false
    private var pageHTML: String?
    /// Clicks the page has reported (tests).
    private(set) var clicks: [String] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: config)
        super.init()
        config.userContentController.addUserScript(WKUserScript(source: PreviewScripts.source, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: PreviewScripts.world))
        config.userContentController.add(WeakScriptHandler(self), contentWorld: PreviewScripts.world, name: PreviewScripts.handlerName)
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.setAccessibilityLabel("Sample page")
    }

    deinit {
        let web = webView
        let cleanup: @MainActor () -> Void = {
            web.navigationDelegate = nil
            web.stopLoading()
            web.configuration.userContentController.removeAllUserScripts()
            web.configuration.userContentController.removeScriptMessageHandler(forName: PreviewScripts.handlerName, contentWorld: PreviewScripts.world)
        }
        if Thread.isMainThread { MainActor.assumeIsolated(cleanup) } else { DispatchQueue.main.async { MainActor.assumeIsolated(cleanup) } }
    }

    // MARK: the text

    /// The sample document: `Template Sample.md` of the bundle (of the sources, in a build run from the package).
    static var sampleText: String {
        if let url = Bundle.main.url(forResource: "Template Sample", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        #if DEBUG || UI_SCRIPT
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Template Sample.md")
        if let text = try? String(contentsOf: sources, encoding: .utf8) { return text }
        #endif
        return "# Sample\n\nThe sample page was not found in the app.\n"
    }

    // MARK: the page

    /// What the page should look like: its stylesheet, the editor's bundled fonts, the outline of one kind (a selector, or
    /// none) and the colour behind it. The first call loads the page; later ones change it in place.
    func show(css: String, fonts: String, outline: String?, background: NSColor?, theme: Theme, typography: Typography) {
        wantedCSS = css
        wantedFonts = fonts
        wantedOutline = outline
        wantedBackground = background
        if let background { webView.underPageBackgroundColor = background }
        if pageHTML == nil {
            let options = RenderOptions(sourceLines: false, standalone: true, sanitize: false, highlight: true,
                                        fallbackTitle: "Sample", style: PreviewStyle(theme: theme, typography: typography))
            let html = Document(text: Self.sampleText).renderHtml(options: options)
            pageHTML = TemplateStore.replacingStyle(inPage: html, with: css)
            appliedCSS = css
            isLoaded = false
            webView.loadHTMLString(pageHTML!, baseURL: PreviewURL.base)
            return
        }
        applyWanted()
    }

    private func applyWanted() {
        guard isLoaded else { return }
        guard wantedCSS != appliedCSS || wantedFonts != appliedFonts || !outlineApplied || wantedOutline != appliedOutline else { return }
        let pairs = TemplateEditor.kinds.map { [$0.key, $0.selector] }
        appliedCSS = wantedCSS
        appliedFonts = wantedFonts
        appliedOutline = wantedOutline
        outlineApplied = true
        jsInFlight += 1
        let script = "__md.setClickKinds(pairs); __md.setFonts(fonts); __md.setStyle(css); __md.outline(outline); return true;"
        webView.callAsyncJavaScript(script, arguments: ["pairs": pairs, "fonts": wantedFonts, "css": wantedCSS, "outline": wantedOutline ?? NSNull()],
                                    in: nil, in: PreviewScripts.world) { [weak self] _ in self?.jsInFlight -= 1 }
    }

    /// Nothing is owed to the page: it is loaded and what was asked for is in.
    var isSettled: Bool {
        isLoaded && jsInFlight == 0 && appliedCSS == wantedCSS && appliedFonts == wantedFonts && outlineApplied && appliedOutline == wantedOutline
    }

    @discardableResult
    func waitUntilSettled(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if isSettled { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return isSettled
    }

    /// Runs `script` (a function body) in the app's world and returns its result, spinning the run loop.
    func evaluate(_ script: String, arguments: [String: Any] = [:], timeout: TimeInterval = 10) -> Any? {
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

    /// The text of the page's own style element: what the sample is styled with.
    func pageStyle() -> String {
        waitUntilSettled()
        return evaluate("const s = document.head.querySelector('style'); return s ? s.textContent : '';") as? String ?? ""
    }

    /// The selector of the outline rule on the page (nil when there is none).
    func pageOutline() -> String? {
        waitUntilSettled()
        let text = evaluate("const s = document.getElementById('md-outline'); return s ? s.textContent : '';") as? String ?? ""
        return text.isEmpty ? nil : text.components(separatedBy: " {").first
    }

    /// The point, in the window, at the middle of the first element of a kind (scrolled into view first), for a click.
    func windowPoint(ofSelector selector: String) -> NSPoint? {
        waitUntilSettled()
        let r = evaluate("""
            const e = document.querySelector(selector);
            if (!e) return null;
            e.scrollIntoView({ block: 'center' });
            const b = e.getBoundingClientRect();
            return [b.left + b.width / 2, b.top + b.height / 2];
            """, arguments: ["selector": selector]) as? [Double]
        guard let r, r.count == 2 else { return nil }
        // (The web view is flipped: its own coordinates run down from the top, like the page's.)
        return webView.convert(NSPoint(x: r[0], y: r[1]), to: nil)
    }

    /// The kind the page's script names for the element at a CSS point (tests, without a click).
    func kind(atSelector selector: String) -> String? {
        evaluate("const e = document.querySelector(selector); return e ? __md.kindAt(e) : null;", arguments: ["selector": selector]) as? String
    }

    // MARK: WKNavigationDelegate, WKScriptMessageHandler

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        // The page came with the stylesheet it was loaded with; the rest goes in now.
        outlineApplied = false
        applyWanted()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page is gone: it is loaded again with what is wanted.
        isLoaded = false
        guard let html = pageHTML else { return }
        appliedCSS = wantedCSS
        webView.loadHTMLString(TemplateStore.replacingStyle(inPage: html, with: wantedCSS), baseURL: PreviewURL.base)
    }

    /// The page loads once; a link in it goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(!isLoaded && navigationAction.navigationType == .other ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "templateClick", let kind = body["kind"] as? String else { return }
        clicks.append(kind)
        onClick?(kind)
    }
}

/// The sample page as a view.
struct TemplateSampleView: NSViewRepresentable {
    let controller: TemplateSampleController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
