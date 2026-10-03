import AppKit
import PDFKit
import WebKit
import MarkdownCore

/// Renders a document's standalone HTML in a web view of its own (so PDF export and printing work
/// with the preview hidden, and without any window being key) and hands out the print operation
/// for it. The page is the one the preview would show, with its `@media print` section in force:
/// light, paginated, links without their URLs.
///
/// Main thread only, and made so by construction rather than by care: the class is `@MainActor`;
/// AppKit reports the end of a print operation on the thread the operation ran on (a background
/// thread when there is no panel), so `PDFJob` and `PrintFinish` hop to the main thread before
/// anything else happens (`PrintCallbacks.onMain`); and `deinit`, which may run on any thread,
/// touches no AppKit object itself.
@MainActor
final class PrintRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let schemeHandler = PreviewSchemeHandler()
    /// A window nobody sees: a web view that is in no window prints nothing.
    let host: NSWindow
    private var onLoad: ((Bool) -> Void)?
    private var loadTimer: Timer?
    private var fontCSS = ""
    private(set) var isClosed = false

    /// How long the page may take to load, its fonts and pictures included (a picture that never
    /// arrives is given up on sooner, see `PreviewScripts`), before the job fails.
    static var loadTimeout: TimeInterval = 30
    /// How long the page waits for its pictures (a server that never answers) before printing without them.
    static var imageWaitMilliseconds = 10_000
    /// Tests: CSS added after the page's own (to show what a rule is worth by taking it away).
    static var extraCSSForTests = ""
    /// Instrumentation (tests): renderers alive, and offscreen windows still on screen.
    static private(set) var live = 0
    static var hostsOnScreen: Int { NSApp.windows.filter { $0.identifier == hostIdentifier && $0.isVisible }.count }
    static let hostIdentifier = NSUserInterfaceItemIdentifier("markdown.print-host")

    /// The page's own print rules from the print info: its margins (WebKit lays pages out by the
    /// stylesheet's `@page` margins, not the print info's).
    let pageCSS: String

    convenience init(documentURL: URL?, info: NSPrintInfo) {
        self.init(documentURL: documentURL, pageSize: Self.printableSize(of: info),
                  pageCSS: String(format: "@page { margin: %.2fpt %.2fpt %.2fpt %.2fpt; }\n", info.topMargin, info.rightMargin, info.bottomMargin, info.leftMargin))
    }

    init(documentURL: URL?, pageSize: NSSize, pageCSS: String = "") {
        self.pageCSS = pageCSS
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: PreviewScripts.source, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: PreviewScripts.world))
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewURL.scheme)
        webView = WKWebView(frame: NSRect(origin: .zero, size: pageSize), configuration: config)
        host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        // On screen but invisible: a page in a window that is never shown is not reliably painted.
        host.alphaValue = 0
        host.ignoresMouseEvents = true
        host.hasShadow = false
        host.isExcludedFromWindowsMenu = true
        host.identifier = Self.hostIdentifier
        super.init()
        schemeHandler.documentURL = { documentURL }
        host.isReleasedWhenClosed = false
        host.contentView = webView
        webView.navigationDelegate = self
        host.orderFrontRegardless()
        Self.live += 1
    }

    deinit {
        // Any thread. `close()` is the way out; this only makes sure the window leaves the screen
        // even if it was never called, on the main thread.
        let host = host
        let web = webView
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                web.navigationDelegate = nil
                web.stopLoading()
                host.orderOut(nil)
                host.contentView = nil
                PrintRenderer.live -= 1
            }
        }
    }

    /// Takes the page down and the window off the screen. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        loadTimer?.invalidate()
        loadTimer = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        host.orderOut(nil)
        host.contentView = nil
        finishLoad(false)
    }

    /// Loads `html` and calls back once (on the main thread) when the page, its fonts and its
    /// pictures are in, or when it failed, timed out or the renderer was closed.
    func load(html: String, fonts: String, completion: @escaping (Bool) -> Void) {
        onLoad = completion
        fontCSS = fonts
        let timer = Timer(timeInterval: Self.loadTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishLoad(false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadTimer = timer
        let parts = PreviewController.split(page: html)
        pendingBody = parts.body
        bodyHasText = Self.hasVisibleText(parts.body)
        webView.loadHTMLString(parts.shell, baseURL: PreviewURL.base)
    }

    private var pendingBody = ""
    /// Whether the page has words on it. A PDF of a page with words but no text layer is a page that
    /// was not painted yet (see `exportPDF`); a document of only pictures, only front matter or only a
    /// rule makes a PDF without text that is quite right.
    private(set) var bodyHasText = false

    /// Text in `body` (HTML) once its tags are gone, non-breaking spaces counting as blanks.
    static func hasVisibleText(_ body: String) -> Bool {
        body.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&#160;", with: " ")
            .contains { !$0.isWhitespace }
    }

    private func finishLoad(_ ok: Bool) {
        loadTimer?.invalidate()
        loadTimer = nil
        let done = onLoad
        onLoad = nil
        done?(ok)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The body goes in the way the preview's does (pictures and links routed first).
        let body = pendingBody
        pendingBody = ""
        webView.callAsyncJavaScript("__md.prepare(0); __md.setFonts(fonts); __md.replaceBody(body, 0); await __md.ready(wait); await new Promise((r) => setTimeout(r, 150)); document.body.offsetHeight; return document.documentElement.scrollHeight;",
                                    arguments: ["fonts": fontCSS + pageCSS + Self.extraCSSForTests, "body": body, "wait": Self.imageWaitMilliseconds],
                                    in: nil, in: PreviewScripts.world) { [weak self] result in
            var ok = true
            if case .failure = result { ok = false }
            if case .success(let h) = result, ((h as? NSNumber)?.doubleValue ?? 0) < 1 { ok = false }
            self?.finishLoad(ok)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoad(false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishLoad(false) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page itself, and nothing else: no frames, no links, no refresh.
        let url = navigationAction.request.url
        let initial = navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
            && url == PreviewURL.base && onLoad != nil
        decisionHandler(initial ? .allow : .cancel)
    }

    /// The print operation for the loaded page. `info` is copied and set up for this page.
    func printOperation(info: NSPrintInfo, saveTo url: URL?) -> NSPrintOperation {
        let info = info.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let size = Self.printableSize(of: info)
        webView.frame = NSRect(origin: .zero, size: size)
        host.setContentSize(size)
        let op = webView.printOperation(with: info)
        op.view?.frame = NSRect(origin: .zero, size: size)
        op.jobTitle = webView.title ?? "Document"
        return op
    }

    nonisolated static func printableSize(of info: NSPrintInfo) -> NSSize {
        NSSize(width: max(100, info.paperSize.width - info.leftMargin - info.rightMargin),
               height: max(100, info.paperSize.height - info.topMargin - info.bottomMargin))
    }
}

// MARK: - the document's side

extension MarkdownDocument {
    /// Margins a printed page of this document gets unless Page Setup changes them (0.75 inch).
    static let defaultPageMargin: CGFloat = 54

    func configurePrintInfo() {
        let info = printInfo
        info.leftMargin = Self.defaultPageMargin
        info.rightMargin = Self.defaultPageMargin
        info.topMargin = Self.defaultPageMargin
        info.bottomMargin = Self.defaultPageMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // Set without NSDocument's setter's side effects: it registers "Change Print Settings" for
        // undo and so marks the document edited, which made every new document "Edited" from its
        // first moment (an Undo item before any typing, a dot on its tab, a question on closing it).
        undoManager?.disableUndoRegistration()
        printInfo = info
        undoManager?.enableUndoRegistration()
        if hasUndoManager { undoManager?.removeAllActions() }
        updateChangeCount(.changeCleared)
    }

    /// The standalone HTML of the document as it is now, from the core (never from the file's
    /// bytes, which may carry the annotation block), rendered on the analysis queue.
    func renderStandalone(completion: @escaping (String) -> Void) {
        let appearance = session.appearance
        let options = RenderOptions(sourceLines: false, standalone: true, sanitize: false, highlight: true,
                                    fallbackTitle: displayName ?? "Untitled",
                                    style: PreviewStyle(theme: appearance.theme, typography: PreviewTypography.make(from: appearance)))
        // With the pictures' declared sizes, as the preview has them: a retina screenshot is printed
        // at its size in points, not at twice it.
        let sizes = PictureSizes(), documentURL = fileURL
        session.coordinator.async({ doc in
            doc.renderHtml(options: PreviewController.withPictureSizes(options, sizes: sizes, doc: doc, documentURL: documentURL))
        }) { html, _ in completion(html) }
    }

    /// Loads the document into an offscreen page and gives the print operation for it (nil if the
    /// page would not load). The caller owns the renderer and closes it when the job is over.
    @MainActor
    func preparePrint(info: NSPrintInfo, saveTo url: URL?, completion: @escaping @MainActor (NSPrintOperation?, PrintRenderer?) -> Void) {
        let renderer = PrintRenderer(documentURL: fileURL, info: info)
        let fonts = PreviewTypography.fontFaceCSS(for: session.appearance)
        renderStandalone { html in
            MainActor.assumeIsolated {
                renderer.load(html: html, fonts: fonts) { ok in
                    guard ok, !renderer.isClosed else { renderer.close(); completion(nil, nil); return }
                    completion(renderer.printOperation(info: info, saveTo: url), renderer)
                }
            }
        }
    }

    /// Writes the document as a paginated PDF at `url`, without a print panel: the same page the
    /// preview shows, printed with its print styles on the document's paper size and margins.
    /// `completion` runs once, on the main thread.
    @MainActor
    public func exportPDF(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        // Say so now, rather than let the print system fail (or ask) later.
        if let problem = ExportError.destinationProblem(url) {
            completion(problem)
            return
        }
        // Info.plist lets the system end the app at once (sudden termination, at log-out) or when it
        // has nothing on screen (automatic termination): fine for documents, which NSDocument guards
        // while they have changes or are being saved, but not for a PDF half written. The window may
        // be closed while the export runs, and the app may be behind others (App Nap would slow the
        // pagination down to a crawl): a user-initiated activity covers all three.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: "Exporting a PDF")
        Self.exportsInFlight += 1
        exportPDF(to: url, attempts: 3) { error in
            Self.exportsInFlight -= 1
            ProcessInfo.processInfo.endActivity(activity)
            completion(error)
        }
    }

    /// PDF exports under way, each holding off sudden and automatic termination (tests).
    @MainActor public static var exportsInFlight = 0

    /// A page that was not painted yet prints as blank pages: look at what was written and try again.
    @MainActor
    private func exportPDF(to url: URL, attempts: Int, completion: @escaping @MainActor (Error?) -> Void) {
        preparePrint(info: printInfo, saveTo: url) { op, renderer in
            guard let op, let renderer else { completion(ExportError.pageDidNotLoad); return }
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            // (What the page shows, not the source: a picture alone, or front matter alone, prints no text.)
            let expectsText = renderer.bodyHasText
            // Not `run()`: the page is paginated by the web content process, which needs the main
            // run loop; the asynchronous form lets it have it.
            let job = PDFJob { ok in
                renderer.close()
                // Reading the PDF back (a 200-page one takes a while) happens off the main thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let wrote = ok && DocumentFileAccess.exists(url)
                    let blank = wrote && expectsText && (PDFDocument(url: url)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    PrintCallbacks.onMain {
                        if blank, attempts > 1 {
                            self.exportPDF(to: url, attempts: attempts - 1, completion: completion)
                        } else {
                            completion(wrote && !blank ? nil : ExportError.printFailed)
                        }
                    }
                }
            }
            op.runModal(for: renderer.host, delegate: job, didRun: #selector(PDFJob.printOperationDidRun(_:success:contextInfo:)),
                        contextInfo: Unmanaged.passRetained(job).toOpaque())
        }
    }

    /// File > Print…: the print panel, as a sheet on the document's window.
    public override func printDocument(_ sender: Any?) {
        MainActor.assumeIsolated {
            // The page loads first; a second Print meanwhile would stack a second sheet.
            guard !isPreparingPrint else { NSSound.beep(); return }
            isPreparingPrint = true
            preparePrint(info: printInfo, saveTo: nil) { [weak self] op, renderer in
                guard let self else { renderer?.close(); return }
                guard let op, let renderer else { self.isPreparingPrint = false; NSSound.beep(); return }
                op.showsPrintPanel = true
                op.showsProgressPanel = true
                let finish = PrintFinish { [weak self] _ in
                    renderer.close()
                    self?.isPreparingPrint = false
                }
                self.lastPrintOperation = op
                self.runModalPrintOperation(op, delegate: finish, didRun: #selector(PrintFinish.documentDidPrint(_:success:contextInfo:)),
                                            contextInfo: Unmanaged.passRetained(finish).toOpaque())
            }
        }
    }

    public override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        // The print panel's path (printDocument:) is asynchronous (the page loads first), so the
        // synchronous route NSDocument offers is not used.
        throw ExportError.useAsynchronousPath
    }
}

enum ExportError: Error, LocalizedError, Equatable {
    case pageDidNotLoad, printFailed, useAsynchronousPath
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .pageDidNotLoad: return "The document could not be prepared for printing."
        case .printFailed: return "The PDF could not be written."
        case .useAsynchronousPath: return "Use File > Print."
        case .cannotWrite(let name): return "The PDF could not be saved as “\(name)” because you don’t have permission to write there."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cannotWrite: return "Choose another folder or file name."
        default: return nil
        }
    }

    /// Why `url` cannot be written, if it plainly cannot: a folder that is missing or read-only,
    /// or a file there that may not be replaced.
    static func destinationProblem(_ url: URL) -> ExportError? {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue, fm.isWritableFile(atPath: folder) else {
            return .cannotWrite(url.lastPathComponent)
        }
        if fm.fileExists(atPath: url.path), !fm.isWritableFile(atPath: url.path) { return .cannotWrite(url.lastPathComponent) }
        return nil
    }
}

/// Where the print callbacks come back to the main thread.
enum PrintCallbacks {
    /// Instrumentation (tests): whether the last print-operation callback arrived on the main thread.
    nonisolated(unsafe) static var lastCallbackWasOnMain: Bool?

    /// Runs `body` on the main thread, later: never inside the print operation's own callout
    /// (closing its window there traps) and never on the thread it ran on.
    static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

/// Keeps the offscreen page alive while the print panel and the job run, and hears the end.
final class PrintFinish: NSObject {
    private let done: @MainActor (Bool) -> Void
    init(_ done: @escaping @MainActor (Bool) -> Void) { self.done = done }

    @objc func documentDidPrint(_ document: NSDocument, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let done = self.done
        PrintCallbacks.lastCallbackWasOnMain = Thread.isMainThread
        if let contextInfo { Unmanaged<PrintFinish>.fromOpaque(contextInfo).release() }
        PrintCallbacks.onMain { done(success) }
    }
}

/// Receives the end of an asynchronous print operation (on the operation's thread).
final class PDFJob: NSObject {
    private let done: @MainActor (Bool) -> Void
    init(done: @escaping @MainActor (Bool) -> Void) { self.done = done }

    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let done = self.done
        PrintCallbacks.lastCallbackWasOnMain = Thread.isMainThread
        if let contextInfo { Unmanaged<PDFJob>.fromOpaque(contextInfo).release() }
        PrintCallbacks.onMain { done(success) }
    }
}
