import AppKit
import PDFKit
import WebKit
import MarkdownCore

/// Renders a document's standalone HTML in a web view of its own (so PDF export and printing work
/// with the preview hidden, and without any window being key) and hands out the print operation
/// for it. The page is the one the preview would show, with its `@media print` section in force:
/// light, paginated, links without their URLs.
final class PrintRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let schemeHandler = PreviewSchemeHandler()
    /// A window nobody sees: a web view that is in no window prints nothing.
    let host: NSWindow
    private var onLoad: ((Bool) -> Void)?
    private weak var anchor: AnyObject?

    init(documentFolder: URL?, pageSize: NSSize) {
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
        super.init()
        schemeHandler.documentFolder = { documentFolder }
        host.isReleasedWhenClosed = false
        host.contentView = webView
        webView.navigationDelegate = self
        host.orderFrontRegardless()
    }

    deinit { close() }

    func close() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        host.orderOut(nil)
        host.contentView = nil
    }

    /// Loads `html` and calls back once the page, its fonts and its pictures are in.
    func load(html: String, fonts: String, completion: @escaping (Bool) -> Void) {
        onLoad = completion
        fontCSS = fonts
        webView.loadHTMLString(html, baseURL: PreviewURL.base)
    }

    private var fontCSS = ""

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript("__md.prepare(0); __md.setFonts(fonts); await __md.ready(); await new Promise((r) => setTimeout(r, 150)); document.body.offsetHeight; return document.documentElement.scrollHeight;", arguments: ["fonts": fontCSS],
                                    in: nil, in: PreviewScripts.world) { [weak self] result in
            var ok = true
            if case .failure = result { ok = false }
            if case .success(let h) = result, ((h as? NSNumber)?.doubleValue ?? 0) < 1 { ok = false }
            let done = self?.onLoad
            self?.onLoad = nil
            done?(ok)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }

    private func finish(_ ok: Bool) {
        let done = onLoad
        onLoad = nil
        done?(ok)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page itself, and nothing else: no frames, no links.
        let url = navigationAction.request.url
        let initial = navigationAction.navigationType == .other && url?.scheme == PreviewURL.scheme
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

    static func printableSize(of info: NSPrintInfo) -> NSSize {
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
        printInfo = info
    }

    /// The standalone HTML of the document as it is now, from the core (never from the file's
    /// bytes, which may carry the annotation block), rendered on the analysis queue.
    func renderStandalone(completion: @escaping (String) -> Void) {
        let appearance = session.appearance
        let options = RenderOptions(sourceLines: false, standalone: true, sanitize: false, highlight: true,
                                    fallbackTitle: displayName ?? "Untitled",
                                    style: PreviewStyle(theme: appearance.theme, typography: PreviewTypography.make(from: appearance)))
        session.coordinator.async({ doc in doc.renderHtml(options: options) }) { html, _ in completion(html) }
    }

    /// Loads the document into an offscreen page and gives the print operation for it (nil if the
    /// page would not load). The renderer lives as long as the operation's completion needs it.
    func preparePrint(info: NSPrintInfo, saveTo url: URL?, completion: @escaping (NSPrintOperation?, PrintRenderer?) -> Void) {
        let folder = PreviewURL.folder(of: fileURL)
        let renderer = PrintRenderer(documentFolder: folder, pageSize: PrintRenderer.printableSize(of: info))
        let fonts = PreviewTypography.fontFaceCSS(for: session.appearance)
        renderStandalone { html in
            renderer.load(html: html, fonts: fonts) { ok in
                guard ok else { renderer.close(); completion(nil, nil); return }
                completion(renderer.printOperation(info: info, saveTo: url), renderer)
            }
        }
    }

    /// Writes the document as a paginated PDF at `url`, without a print panel: the same page the
    /// preview shows, printed with its print styles on the document's paper size and margins.
    public func exportPDF(to url: URL, completion: @escaping (Error?) -> Void) {
        exportPDF(to: url, attempts: 3, completion: completion)
    }

    /// A page that was not painted yet prints as blank pages: look at what was written and try again.
    private func exportPDF(to url: URL, attempts: Int, completion: @escaping (Error?) -> Void) {
        preparePrint(info: printInfo, saveTo: url) { op, renderer in
            guard let op, let renderer else { completion(ExportError.pageDidNotLoad); return }
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            // Not `run()`: the page is paginated by the web content process, which needs the main
            // run loop; the asynchronous form lets it have it.
            let box = PDFJob(renderer: renderer) { ok in
                // After the operation has fully unwound: closing the window inside its callback traps.
                DispatchQueue.main.async {
                    renderer.close()
                    let wrote = ok && DocumentFileAccess.exists(url)
                    let blank = wrote && (PDFDocument(url: url)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !self.session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if blank, attempts > 1 {
                        self.exportPDF(to: url, attempts: attempts - 1, completion: completion)
                    } else {
                        completion(wrote && !blank ? nil : ExportError.printFailed)
                    }
                }
            }
            op.runModal(for: renderer.host, delegate: box, didRun: #selector(PDFJob.printOperationDidRun(_:success:contextInfo:)),
                        contextInfo: Unmanaged.passRetained(box).toOpaque())
        }
    }

    /// File > Print…: the print panel, as a sheet on the document's window.
    public override func printDocument(_ sender: Any?) {
        preparePrint(info: printInfo, saveTo: nil) { [weak self] op, renderer in
            guard let self, let op, let renderer else { NSSound.beep(); return }
            op.showsPrintPanel = true
            op.showsProgressPanel = true
            let box = PrintFinish(renderer)
            self.runModalPrintOperation(op, delegate: box, didRun: #selector(PrintFinish.printOperationDidRun(_:success:contextInfo:)),
                                        contextInfo: Unmanaged.passRetained(box).toOpaque())
        }
    }

    public override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        // The print panel's path (printDocument:) is asynchronous (the page loads first), so the
        // synchronous route NSDocument offers is not used.
        throw ExportError.useAsynchronousPath
    }
}

enum ExportError: Error, LocalizedError {
    case pageDidNotLoad, printFailed, useAsynchronousPath

    var errorDescription: String? {
        switch self {
        case .pageDidNotLoad: return "The document could not be prepared for printing."
        case .printFailed: return "The PDF could not be written."
        case .useAsynchronousPath: return "Use File > Print."
        }
    }
}

/// Keeps the offscreen page alive while the print panel and the job run.
final class PrintFinish: NSObject {
    let renderer: PrintRenderer
    init(_ renderer: PrintRenderer) { self.renderer = renderer }

    @objc func printOperationDidRun(_ document: NSDocument, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [renderer] in renderer.close() }
        if let contextInfo { Unmanaged<PrintFinish>.fromOpaque(contextInfo).release() }
    }
}

/// Receives the end of an asynchronous print operation.
final class PDFJob: NSObject {
    let renderer: PrintRenderer
    let done: (Bool) -> Void
    init(renderer: PrintRenderer, done: @escaping (Bool) -> Void) { self.renderer = renderer; self.done = done }

    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PDFJob>.fromOpaque(contextInfo).release() }
        done(success)
    }
}
