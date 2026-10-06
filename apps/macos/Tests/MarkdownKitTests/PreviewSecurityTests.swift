import AppKit
import Network
import WebKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// What a hostile Markdown file can do in the preview: run nothing, navigate nowhere, reach the
/// network only to fetch pictures, and read through the app's scheme only
/// what a picture may be, for display.
@MainActor
final class PreviewSecurityTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func pump(_ s: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private func openSplit(_ text: String) throws -> (MarkdownDocument, EditorWindowController) {
        let settings = isolatedSettings()
        settings.defaultLayout = .split
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let url = tmp.appendingPathComponent("hostile.md")
        try Data(text.utf8).write(to: url)
        doc.fileURL = url
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        XCTAssertTrue(doc.session.waitUntilStyled())
        XCTAssertTrue(wc.previewController.waitUntilSettled())
        return (doc, wc)
    }

    func testJavaScriptIsOffInEveryWebViewTheAppMakes() throws {
        let (doc, wc) = try openSplit("x\n")
        XCTAssertFalse(wc.previewController.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let renderer = PrintRenderer(documentURL: nil, pageSize: NSSize(width: 300, height: 300))
        XCTAssertFalse(renderer.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        renderer.close()
        doc.close()
    }

    func testAHostileDocumentRunsNothingNavigatesNowhereAndPostsNothing() throws {
        let server = try RecordingServer()
        defer { server.stop() }
        XCTAssertTrue(spin(timeout: 5) { server.port != nil })
        let port = server.port!
        let secret = tmp.appendingPathComponent("secret.txt")
        try Data("TOP-SECRET".utf8).write(to: secret)
        let md = """
        # Hostile

        <script>document.body.setAttribute('data-ran', 'script'); location = 'http://127.0.0.1:\(port)/script';</script>

        <img src="x" onerror="document.body.setAttribute('data-ran', 'onerror')">

        <iframe src="mdoc://doc/picture?src=\(secret.path)"></iframe>
        <iframe src="mdoc://doc/rel/secret.txt"></iframe>
        <iframe srcdoc="<p>framed</p>"></iframe>
        <iframe src="http://127.0.0.1:\(port)/frame"></iframe>
        <object data="http://127.0.0.1:\(port)/object"></object>
        <embed src="http://127.0.0.1:\(port)/embed">

        <meta http-equiv="refresh" content="0;url=http://127.0.0.1:\(port)/refresh">

        <form id="f" action="http://127.0.0.1:\(port)/form" method="get"><input name="q" value="secret"><button id="b">go</button></form>

        <style>@font-face { font-family: leak; src: url(http://127.0.0.1:\(port)/font); } p.leak { font-family: leak; }</style>
        <link rel="stylesheet" href="http://127.0.0.1:\(port)/style.css">
        <base href="http://127.0.0.1:\(port)/base/">

        <p class="leak">Text in a remote font.</p>

        <a id="js" href="javascript:document.body.setAttribute('data-ran', 'link')">js link</a>
        <a id="data" href="data:text/html,<script>alert(1)</script>">data link</a>

        After all of it.
        """
        var opened: [URL] = []
        LinkOpener.opened = { opened.append($0); return true }
        defer { LinkOpener.opened = nil }
        let (doc, wc) = try openSplit(md)
        let p = wc.previewController
        pump(1.5)
        // Nothing ran.
        XCTAssertNil(p.evaluateSync("return document.body.getAttribute('data-ran');") as? String)
        // Clicks: the button submits the form, the links try to go somewhere.
        _ = p.evaluateSync("document.getElementById('b').click(); return 1;")
        _ = p.evaluateSync("document.getElementById('js').click(); return 1;")
        _ = p.evaluateSync("document.getElementById('data').click(); return 1;")
        pump(1.0)
        XCTAssertNil(p.evaluateSync("return document.body.getAttribute('data-ran');") as? String)
        XCTAssertEqual(opened, [], "nothing was handed to another application")
        XCTAssertEqual(p.webView.url, PreviewURL.base, "the page is still the page")
        XCTAssertEqual(p.evaluateSync("return document.getElementById('md') !== null && document.body.innerText.includes('After all of it.');") as? Bool, true)
        // No frame got a document, and nothing but pictures reached the network.
        let frames = p.evaluateSync("return [...document.querySelectorAll('iframe')].map(f => { try { return f.contentDocument ? f.contentDocument.body.innerText : 'none'; } catch (e) { return 'cross-origin'; } }).join('|');") as? String
        XCTAssertFalse(frames?.contains("TOP-SECRET") ?? true, "frames: \(frames ?? "nil")")
        XCTAssertFalse(frames?.contains("framed") ?? true, "frames: \(frames ?? "nil")")
        XCTAssertEqual(server.paths, [], "the document reached the network: \(server.paths)")
        XCTAssertFalse(p.schemeHandler.requests.contains { $0.absoluteString.contains("secret") }, "\(p.schemeHandler.requests)")
        doc.close()
    }

    /// The control for the test above: the same kind of page without the core's policy, in a web
    /// view with JavaScript off, does reach the network (fonts, stylesheets, frames, plugins).
    /// So JavaScript-off alone is not the wall; the policy is.
    func testWithoutThePolicyRawHTMLWouldReachTheNetwork() throws {
        let server = try RecordingServer()
        defer { server.stop() }
        XCTAssertTrue(spin(timeout: 5) { server.port != nil })
        let port = server.port!
        let md = "<style>@font-face { font-family: leak; src: url(http://127.0.0.1:\(port)/font); } p { font-family: leak; }</style>\n<link rel=\"stylesheet\" href=\"http://127.0.0.1:\(port)/style.css\">\n<iframe src=\"http://127.0.0.1:\(port)/frame\"></iframe>\n\ntext\n"
        let page = Document(text: md).renderHtml(options: RenderOptions(sourceLines: false, standalone: true, sanitize: false, highlight: false, fallbackTitle: "", style: nil))
        XCTAssertTrue(page.contains("Content-Security-Policy"))
        let unprotected = page.components(separatedBy: "\n").filter { !$0.contains("Content-Security-Policy") }.joined(separator: "\n")
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        web.loadHTMLString(unprotected, baseURL: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertTrue(spin(timeout: 5) { Set(server.paths).isSuperset(of: ["/style.css", "/frame"]) }, "\(server.paths)")
        print("without the policy the page fetched: \(server.paths)")
    }

    /// Pictures are the one thing a document may fetch:
    /// the server sees that request, and only that.
    func testPicturesAreTheOnlyThingFetched() throws {
        let server = try RecordingServer()
        defer { server.stop() }
        XCTAssertTrue(spin(timeout: 5) { server.port != nil })
        let port = server.port!
        let md = "![remote](http://127.0.0.1:\(port)/picture.png)\n\n<p style=\"background: url(http://127.0.0.1:\(port)/background.png)\">styled</p>\n\n<style>@import url(http://127.0.0.1:\(port)/import.css);</style>\n"
        let (doc, _) = try openSplit(md)
        XCTAssertTrue(spin(timeout: 5) { server.paths.contains("/picture.png") }, "\(server.paths)")
        pump(0.5)
        // A style attribute's background is a picture too (img-src); an @import is not.
        XCTAssertFalse(server.paths.contains("/import.css"), "\(server.paths)")
        print("fetched by a hostile document's pictures: \(server.paths)")
        doc.close()
    }

    /// What the scheme serves for a document: only what `DocumentFileAccess` would let the editor
    /// show, and a file served is shown, never readable by the page (its JavaScript is off: there
    /// is no way to put a file's bytes into a URL).
    func testTheSchemeServesNoMoreThanTheEditorShows() throws {
        let png = try Data(contentsOf: Fixtures.root.appendingPathComponent("scripts/macos/ui/fixtures/images/small.png"))
        try png.write(to: tmp.appendingPathComponent("ok.png"))
        let outside = tmp.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        try png.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        // A symbolic link in the folder to a file outside it: followed, as the editor follows it.
        try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("link.png"), withDestinationURL: outside)
        let md = """
        ![ok](ok.png)

        ![link](link.png)

        <img alt="rel-escape" src="mdoc://doc/rel/..%2F\(outside.lastPathComponent)">

        <img alt="rel-dots" src="mdoc://doc/rel/%2e%2e/\(outside.lastPathComponent)">

        <img alt="old-abs-route" src="mdoc://doc/abs\(outside.path)">

        <img alt="not-a-picture" src="/etc/hosts">

        <video poster="mdoc://doc/rel/..%2F..%2Fetc%2Fhosts"></video>
        """
        let (doc, wc) = try openSplit(md)
        let p = wc.previewController
        func state() -> [String: String] {
            p.evaluateSync("const o = {}; for (const i of document.images) o[i.alt] = i.complete ? (i.naturalWidth > 0 ? 'loaded' : 'broken') : 'loading'; return o;") as? [String: String] ?? [:]
        }
        XCTAssertTrue(spin(timeout: 5) { !state().values.contains("loading") && state().count == 6 }, "\(state())")
        let s = state()
        XCTAssertEqual(s["ok"], "loaded")
        XCTAssertEqual(s["link"], "loaded", "a link to a picture is followed")
        XCTAssertEqual(s["rel-escape"], "broken", "an escaped slash cannot climb out of the folder")
        XCTAssertEqual(s["rel-dots"], "broken")
        XCTAssertEqual(s["old-abs-route"], "broken", "there is no route by absolute path")
        XCTAssertEqual(s["not-a-picture"], "broken", "served but it is not a picture")
        XCTAssertGreaterThanOrEqual(p.schemeHandler.denied, 3)
        // The rule they share (`DocumentFileAccess`) agrees on each.
        XCTAssertNotNil(DocumentFileAccess.pictureURL(for: "link.png", documentURL: doc.fileURL))
        XCTAssertEqual(DocumentFileAccess.pictureURL(for: "/etc/hosts", documentURL: doc.fileURL), URL(fileURLWithPath: "/etc/hosts"))
        doc.close()
    }

    /// A link to a program is shown in the Finder, never run, from the preview or the editor.
    func testALinkToAProgramIsRevealedNotRun() throws {
        for (path, runs) in [("/Applications/Calculator.app", true), ("/tmp/x.command", true), ("/tmp/install.pkg", true), ("/tmp/s.sh", true),
                             ("/tmp/notes.md", false), ("/tmp/paper.pdf", false), ("/tmp/picture.png", false), ("/tmp/page.html", false)] {
            XCTAssertEqual(LinkOpener.launchesSomething(URL(fileURLWithPath: path)), runs, path)
        }
        let tool = tmp.appendingPathComponent("tool")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertTrue(LinkOpener.launchesSomething(tool), "an executable without an extension")
        let text = tmp.appendingPathComponent("README")
        try Data("hi".utf8).write(to: text)
        XCTAssertFalse(LinkOpener.launchesSomething(text))
    }
}

/// A TCP server on the loopback interface that records the path of every HTTP request it gets
/// and answers 404.
final class RecordingServer {
    private let listener: NWListener
    private var held: [NWConnection] = []
    private(set) var paths: [String] = []
    private(set) var port: UInt16?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.held.append(c)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, let head = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first {
                    let parts = head.split(separator: " ")
                    if parts.count >= 2 { self?.paths.append(String(parts[1])) }
                }
                c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        held.forEach { $0.cancel() }
    }
}
