import AppKit
import ImageIO
import UniformTypeIdentifiers
// A URL scheme task is answered on the main thread only (the file is read elsewhere and the
// answer hops back), which WebKit's annotations cannot express.
@preconcurrency import WebKit
import MarkdownCore

/// How a window shows its document: the editor alone, the editor beside the preview, or the
/// preview alone (read-only).
public enum LayoutMode: String, CaseIterable, Sendable {
    case editor, split, preview

    public var title: String {
        switch self {
        case .editor: return "Editor"
        case .split: return "Editor and Preview"
        case .preview: return "Preview"
        }
    }

    public var symbolName: String {
        switch self {
        case .editor: return "doc.plaintext"
        case .split: return "rectangle.split.2x1"
        case .preview: return "eye"
        }
    }

    public var showsEditor: Bool { self != .preview }
    public var showsPreview: Bool { self != .editor }
}

// MARK: - the preview's addresses

/// The preview page lives at `mdoc://doc/rel/`; everything it loads goes through the app's own
/// scheme handler (`PreviewSchemeHandler`), never through `file:`. The page's script rewrites
/// every picture and every link that is not to the web, before the page can load it, to carry
/// the destination exactly as the Markdown wrote it, so the same functions the editor uses decide
/// what it is (`DocumentFileAccess.pictureURL`, `LinkOpener.url`):
///
///     mdoc://doc/picture?src=<as written>   a picture (`<img src>`), resolved and checked like the editor's
///     mdoc://doc/link?href=<as written>     a link to a file (opened only on a click, see LinkPolicy)
///     mdoc://doc/font/<name>                one of the bundled writing fonts
///     mdoc://doc/rel/<path>                 anything else the page's raw HTML refers to by a relative
///                                           path (a stylesheet, `srcset`): the document's folder and below
public enum PreviewURL {
    public static let scheme = "mdoc"
    public static let host = "doc"
    public static let base = URL(string: "mdoc://doc/rel/")!

    public enum Resolution: Equatable {
        case file(URL)
        case font(String)
        /// A link as written in the document (for `LinkOpener.url`).
        case link(String)
        /// Refused: outside what the document may read.
        case denied
        /// Not one of ours.
        case unknown
    }

    /// The address the page loads the picture `src` (as written) from.
    public static func picture(_ src: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.path = "/picture"
        c.queryItems = [URLQueryItem(name: "src", value: src)]
        return c.url!
    }

    /// Where a request for `url` is served from. `documentURL` is nil for a document that was
    /// never saved (relative paths then have no base).
    public static func resolve(_ url: URL, documentURL: URL?) -> Resolution {
        guard url.scheme == scheme, url.host == host else { return .unknown }
        // Percent-decoded path components, the way the file system will see them.
        let path = url.path(percentEncoded: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch path {
        case "/picture":
            guard let src = query.first(where: { $0.name == "src" })?.value,
                  let file = DocumentFileAccess.pictureURL(for: src, documentURL: documentURL),
                  file.isFileURL, DocumentFileAccess.mayRead(file, documentURL: documentURL) else { return .denied }
            return .file(file)
        case "/link":
            guard let href = query.first(where: { $0.name == "href" })?.value else { return .denied }
            return .link(href)
        default:
            break
        }
        if path.hasPrefix("/font/") {
            return .font(String(path.dropFirst("/font/".count)))
        }
        if path.hasPrefix("/rel/") {
            // WebKit has already taken `..` segments out; a decoded `%2F` could still spell one,
            // so the result must stay in the document's folder.
            guard let folder = documentURL?.deletingLastPathComponent().standardizedFileURL else { return .denied }
            let relative = String(path.dropFirst("/rel/".count))
            let file = URL(fileURLWithPath: relative, isDirectory: false, relativeTo: URL(fileURLWithPath: folder.path, isDirectory: true)).standardizedFileURL
            let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard file.path.hasPrefix(base), DocumentFileAccess.mayRead(file, documentURL: documentURL) else { return .denied }
            return .file(file)
        }
        return .denied
    }
}

// MARK: - what a click on a link does

/// What the preview does with a navigation. A pure function of the URL and what kind of
/// navigation it is, so every case can be listed in a table.
public enum LinkAction: Equatable {
    /// The page itself loading, or a fragment inside it: let the web view go ahead.
    case allow
    /// Scroll the preview to the element with this id (the web view does not navigate).
    case scrollToFragment(String)
    /// Hand to the default application (a browser, Mail, the app that owns a file).
    case open(URL)
    /// A note of the library: a wikilink's target (`Title.md` as the page spells it, decoded) and its
    /// heading's anchor, if it has one. Only in notes mode: the window finds the note.
    case openNote(target: String, fragment: String?)
    /// Do nothing.
    case ignore
}

public enum LinkPolicy {
    /// A link to a note as the preview writes a wikilink's: a relative path to a note file, `./` in
    /// front when the first folder would read as a scheme (`Note: Title.md`) or the path as a host
    /// (`.//host/x.md`), `%25` and `%3F` for the `%` and `?` a file name has, `#slug` for a heading.
    /// The target comes back as the name of the note (escapes decoded, prefix gone). Nil for anything
    /// else: a web address, a path out of the folder (`../`, `/`, `~/`), a file that is not a note.
    public static func noteLink(href: String) -> (target: String, fragment: String?)? {
        var raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        var fragment: String?
        if let hash = raw.firstIndex(of: "#") {
            fragment = String(raw[raw.index(after: hash)...]).removingPercentEncoding
            raw = String(raw[..<hash])
        }
        var prefixed = false
        while raw.hasPrefix("./") {
            raw.removeFirst(2)
            prefixed = true
        }
        // `.//host/x` is `//host/x` written so that it is not another host: it names `host/x`.
        if prefixed { while raw.hasPrefix("/") { raw.removeFirst() } }
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        if !prefixed, let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/") { return nil }
        let name = raw.removingPercentEncoding ?? raw
        // Checked again once decoded: `%2F` and `%2E` spell the same ways out of the folder.
        guard !name.hasPrefix("/"), !name.hasPrefix("~"), name != "..", !name.hasPrefix("../"), !name.contains("/../"), !name.hasSuffix("/.."), DocumentFileAccess.noteExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return (name, fragment)
    }

    /// - `isLinkActivation`: the user clicked a link (a drop, a script or a redirect is not).
    /// - `isMainFrame`: the navigation targets the page, not a frame a document's raw HTML made.
    /// - `isInitialLoad`: the app's own `loadHTMLString` for the page.
    public static func decide(url: URL?, isLinkActivation: Bool, isMainFrame: Bool, isInitialLoad: Bool,
                              documentURL: URL?, notes: Bool = false) -> LinkAction {
        guard let url else { return .ignore }
        // The app's own load of the page, and nothing else that happens to use the scheme (a
        // `<meta refresh>` or a frame in the document's raw HTML).
        if isInitialLoad, isMainFrame, url == PreviewURL.base { return .allow }
        guard isMainFrame, isLinkActivation else { return .ignore }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel":
            return .open(url)
        case PreviewURL.scheme:
            // A fragment of the page itself.
            let samePage = url.host == PreviewURL.host && (url.path == "/rel/" || url.path == "/rel")
            if samePage {
                guard let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty else { return .ignore }
                return .scrollToFragment(fragment)
            }
            // A link the page's script routed here, as written: the editor's own rule (Cmd-click).
            if case .link(let href) = PreviewURL.resolve(url, documentURL: documentURL) {
                if href.hasPrefix("#") { return href.count > 1 ? .scrollToFragment(String(href.dropFirst()).removingPercentEncoding ?? String(href.dropFirst())) : .ignore }
                if notes, let note = noteLink(href: href) { return .openNote(target: note.target, fragment: note.fragment) }
                return LinkOpener.url(for: href, documentURL: documentURL).map { .open($0) } ?? .ignore
            }
            return .ignore
        default:
            // `file:` and everything else reach here only if the script did not route them: the
            // script routes them all, so this is a page that bypassed it.
            return .ignore
        }
    }
}

// MARK: - scroll synchronisation (pure math)

/// A source line and where its element sits in the preview (points from the top of the content).
public struct ScrollAnchor: Equatable {
    public var line: Double
    public var y: Double
    public init(line: Double, y: Double) { self.line = line; self.y = y }
}

/// Source line numbers of a text (0-based; `\n`, `\r\n` and a lone `\r` end a line, as in the core).
public struct LineTable {
    public private(set) var starts: [Int] = [0]
    public private(set) var length = 0

    public init(_ text: NSString) {
        length = text.length
        var buffer = [unichar](repeating: 0, count: 4096)
        var pos = 0
        var previousWasCR = false
        while pos < length {
            let n = min(buffer.count, length - pos)
            text.getCharacters(&buffer, range: NSRange(location: pos, length: n))
            for i in 0..<n {
                let c = buffer[i]
                if c == 0x0A {
                    if !previousWasCR { starts.append(pos + i + 1) } else { starts[starts.count - 1] = pos + i + 1 }
                    previousWasCR = false
                } else if c == 0x0D {
                    starts.append(pos + i + 1)
                    previousWasCR = true
                } else {
                    previousWasCR = false
                }
            }
            pos += n
        }
    }

    public var lineCount: Int { starts.count }

    /// The line holding UTF-16 offset `location` (clamped).
    public func line(at location: Int) -> Int {
        let p = min(max(location, 0), length)
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= p { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Where `line` starts, and how long it is (terminator excluded).
    public func range(ofLine line: Int) -> NSRange {
        let l = min(max(line, 0), starts.count - 1)
        let s = starts[l]
        let e = l + 1 < starts.count ? starts[l + 1] : length
        return NSRange(location: s, length: max(0, e - s))
    }

    /// `line + fraction`: the line holding `location` and how far into it (by characters).
    public func position(at location: Int) -> Double {
        let l = line(at: location)
        let r = range(ofLine: l)
        guard r.length > 0 else { return Double(l) }
        return Double(l) + min(1, Double(location - r.location) / Double(r.length))
    }

    /// The offset of fractional position `p` (the inverse of `position(at:)`).
    public func location(at p: Double) -> Int {
        let clamped = min(max(p, 0), Double(starts.count - 1) + 0.999_999)
        let l = Int(clamped.rounded(.down))
        let r = range(ofLine: l)
        return r.location + Int(((clamped - Double(l)) * Double(r.length) + 1e-6).rounded(.down))
    }
}

public enum ScrollSync {
    /// The preview's y for source position `line` (fractional), interpolating between the elements
    /// either side of it. `anchors` are sorted by line; `endLine`/`endY` close the last interval
    /// (the end of the document) and `startY` the first (the top of the content). The same
    /// algorithm runs in the preview's script (`PreviewScripts`), which a test compares.
    public static func y(forLine line: Double, anchors: [ScrollAnchor], startY: Double, endLine: Double, endY: Double) -> Double {
        let all = closed(anchors, startY: startY, endLine: endLine, endY: endY)
        let l = min(max(line, all[0].line), all[all.count - 1].line)
        var lo = 0, hi = all.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if all[mid].line <= l { lo = mid } else { hi = mid }
        }
        let a = all[lo], b = all[hi]
        guard b.line > a.line else { return a.y }
        return a.y + (l - a.line) / (b.line - a.line) * (b.y - a.y)
    }

    /// The source position at preview y (the inverse of `y(forLine:)`).
    public static func line(forY y: Double, anchors: [ScrollAnchor], startY: Double, endLine: Double, endY: Double) -> Double {
        let all = closed(anchors, startY: startY, endLine: endLine, endY: endY)
        let v = min(max(y, all[0].y), all[all.count - 1].y)
        var lo = 0, hi = all.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if all[mid].y <= v { lo = mid } else { hi = mid }
        }
        let a = all[lo], b = all[hi]
        guard b.y > a.y else { return a.line }
        return a.line + (v - a.y) / (b.y - a.y) * (b.line - a.line)
    }

    private static func closed(_ anchors: [ScrollAnchor], startY: Double, endLine: Double, endY: Double) -> [ScrollAnchor] {
        var all: [ScrollAnchor] = []
        if anchors.first.map({ $0.line > 0 }) ?? true { all.append(ScrollAnchor(line: 0, y: startY)) }
        all.append(contentsOf: anchors)
        let last = all[all.count - 1]
        all.append(ScrollAnchor(line: max(endLine, last.line + 1), y: max(endY, last.y)))
        return all
    }

    /// Clamps a scroll offset to what the view can show.
    public static func clamp(_ offset: Double, contentHeight: Double, viewportHeight: Double, minimum: Double = 0) -> Double {
        min(max(offset, minimum), max(minimum, contentHeight - viewportHeight))
    }

    /// A scroll the app made itself comes back as an event: it is an echo when the position is
    /// the one that was set (within a point), and must not be answered.
    public static func isEcho(position: Double, lastSet: Double?) -> Bool {
        guard let lastSet else { return false }
        return abs(position - lastSet) < 1.5
    }

    /// How long to wait after the last change before rendering: short for small documents, longer
    /// for large ones (an update every keystroke would keep the analysis queue busy).
    public static func debounce(forLength length: Int) -> TimeInterval {
        0.06 + min(0.5, Double(length) / 2_000_000)
    }
}

// MARK: - updating the page by the part that changed

/// How to turn the body the page holds into a new one without sending all of it: keep the first
/// `start` UTF-16 units, put `insert` in place of the units up to `oldEnd`, and keep the rest with
/// every `data-line="N"` in it moved by `lineDelta` (typing a Return renumbers every block below).
/// Computed off the main thread; handing a megabyte of HTML to the page held the main thread for
/// about 50 ms, a patch for a keystroke takes well under one.
public struct BodyPatch: Equatable {
    public var start: Int
    public var oldEnd: Int
    public var insert: String
    public var lineDelta: Int
    /// The new body's length in UTF-16 units (the page checks it got the same).
    public var newLength: Int
    /// The old body's length, which the page checks it holds before patching.
    public var oldLength: Int

    /// The patch from `old` to `new`, or nil when it would not be much smaller than `new` itself.
    public static func make(from old: String, to new: String) -> BodyPatch? {
        let a = Array(old.utf16), b = Array(new.utf16)
        // Common prefix, not ending inside a surrogate pair.
        var p = 0
        let limit = min(a.count, b.count)
        while p < limit, a[p] == b[p] { p += 1 }
        if p > 0, UTF16.isLeadSurrogate(a[p - 1]) { p -= 1 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        let marker = Array("data-line=\"".utf16)
        // Not ending inside a `data-line="N"` (the texts agree up to the first renumbered digit):
        // the kept tail must start with whole attributes, or the page's shift would miss one.
        var q = p
        while q > 0, isDigit(a[q - 1]) { q -= 1 }
        if q >= marker.count, Array(a[(q - marker.count)..<q]) == marker {
            p = q - marker.count
        } else if q == p {
            for k in stride(from: min(marker.count - 1, p), through: 1, by: -1) where Array(a[(p - k)..<p]) == Array(marker[0..<k]) {
                p -= k
                break
            }
        }
        // Common suffix from the end, where data-line values may differ by one constant.
        var i = a.count, j = b.count
        var delta: Int?
        func run(_ s: [UInt16], endingAt e: Int) -> (start: Int, value: Int?, isDataLine: Bool) {
            var k = e
            while k > 0, isDigit(s[k - 1]) { k -= 1 }
            let digits = s[k..<e]
            let value = digits.count <= 9 ? digits.reduce(0) { $0 * 10 + Int($1 - 48) } : nil
            let isDataLine = k >= marker.count && Array(s[(k - marker.count)..<k]) == marker && e < s.count && s[e] == 34 // "
            return (k, value, isDataLine)
        }
        while i > p, j > p {
            let x = a[i - 1], y = b[j - 1]
            if !isDigit(x) || !isDigit(y) {
                guard x == y else { break }
                i -= 1; j -= 1
                continue
            }
            let ra = run(a, endingAt: i), rb = run(b, endingAt: j)
            if ra.isDataLine, rb.isDataLine, let va = ra.value, let vb = rb.value, ra.start >= p, rb.start >= p {
                let d = vb - va
                if delta == nil { delta = d }
                guard d == delta else { break }
            } else {
                guard !ra.isDataLine, !rb.isDataLine, a[ra.start..<i] == b[rb.start..<j], ra.start >= p, rb.start >= p else { break }
            }
            i = ra.start; j = rb.start
        }
        // Not starting the kept tail inside a surrogate pair.
        while j < b.count, i < a.count, UTF16.isTrailSurrogate(b[j]) { i += 1; j += 1 }
        guard j >= p, i >= p else { return nil }
        let insert = String(decoding: b[p..<j], as: UTF16.self)
        // Worth it only when far smaller than the whole.
        guard insert.utf16.count * 4 < b.count || b.count < 4096 else { return nil }
        return BodyPatch(start: p, oldEnd: i, insert: insert, lineDelta: delta ?? 0, newLength: b.count, oldLength: a.count)
    }

    /// The new body, from the old one (what the page's script does, for tests).
    public func apply(to old: String) -> String? {
        let a = Array(old.utf16)
        guard a.count == oldLength, start <= oldEnd, oldEnd <= a.count else { return nil }
        var tail = String(decoding: a[oldEnd...], as: UTF16.self)
        if lineDelta != 0 {
            let re = try! NSRegularExpression(pattern: "data-line=\"(\\d+)\"")
            let ns = tail as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: tail, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let n = Int(ns.substring(with: m.range(at: 1)))! + lineDelta
                out += "data-line=\"\(n)\""
                last = NSMaxRange(m.range)
            }
            out += ns.substring(from: last)
            tail = out
        }
        return String(decoding: a[..<start], as: UTF16.self) + insert + tail
    }
}

// MARK: - serving the preview's files

/// Answers `mdoc://` requests: pictures and files (resolved and checked by `DocumentFileAccess`,
/// the sandbox seam) and the bundled fonts. WebKit calls it
/// on the main thread and its replies are made there; the reading happens on a background queue.
@MainActor
public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The document whose pictures these are; nil for an untitled document.
    public var documentURL: () -> URL? = { nil }
    public var fontDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
    /// Instrumentation: the last URLs asked for, and how many were refused.
    public private(set) var requests: [URL] = []
    public private(set) var denied = 0
    public private(set) var failed = 0
    public private(set) var served = 0

    private let queue = DispatchQueue(label: "markdown.preview.files", qos: .userInitiated, attributes: .concurrent)
    /// Tasks started and not yet answered or stopped. (Not a set of stopped ones: an identifier
    /// is an address, which a later task may reuse.)
    private var open = Set<ObjectIdentifier>()
    private struct CacheEntry { var data: Data; var modified: Date? }
    private let cache = NSCache<NSURL, AnyObject>()
    private static let fontNames = try! NSRegularExpression(pattern: "^iAWriter(Mono|Duo|Quattro)S-(Regular|Bold|Italic|BoldItalic)\\.ttf$")

    public override init() {
        super.init()
        cache.totalCostLimit = 64 << 20
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        requests.append(url)
        if requests.count > 200 { requests.removeFirst(requests.count - 100) }
        let id = ObjectIdentifier(task as AnyObject)
        open.insert(id)
        switch PreviewURL.resolve(url, documentURL: documentURL()) {
        case .denied, .unknown, .link:
            // A link is followed by a click (LinkPolicy), never loaded into the page.
            denied += 1
            fail(task, id: id, status: 403, url: url)
        case .font(let name):
            guard Self.fontNames.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil,
                  let dir = fontDirectory else { failed += 1; fail(task, id: id, status: 404, url: url); return }
            load(dir.appendingPathComponent(name), for: task, id: id, url: url, mime: "font/ttf")
        case .file(let file):
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            load(file, for: task, id: id, url: url, mime: mime)
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Answering a stopped task raises an exception.
        open.remove(ObjectIdentifier(task as AnyObject))
    }

    /// Instrumentation (tests): requests started and not yet answered.
    var unanswered: Int { open.count }

    private func load(_ file: URL, for task: any WKURLSchemeTask, id: ObjectIdentifier, url: URL, mime: String) {
        let key = file as NSURL
        let modified = DocumentFileAccess.modificationDate(of: file)
        if let entry = cache.object(forKey: key) as? CacheBox, entry.value.modified == modified, modified != nil {
            reply(task, id: id, url: url, mime: mime, data: entry.value.data)
            return
        }
        // The task is only touched again on the main actor, where it came from.
        nonisolated(unsafe) let task = task
        queue.async { [weak self] in
            let data = try? DocumentFileAccess.read(file)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let data else { self.failed += 1; self.fail(task, id: id, status: 404, url: url); return }
                    self.cache.setObject(CacheBox(CacheEntry(data: data, modified: modified)), forKey: key, cost: data.count)
                    self.reply(task, id: id, url: url, mime: mime, data: data)
                }
            }
        }
    }

    private final class CacheBox: NSObject {
        let value: CacheEntry
        init(_ v: CacheEntry) { value = v }
    }

    private func reply(_ task: any WKURLSchemeTask, id: ObjectIdentifier, url: URL, mime: String, data: Data) {
        guard open.remove(id) != nil else { return }
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        served += 1
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, id: ObjectIdentifier, status: Int, url: URL) {
        guard open.remove(id) != nil else { return }
        // An answer, not an error: the page shows the image's alt text or the broken-image icon.
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) {
            task.didReceive(response)
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }
}

// MARK: - the script the app runs inside the page

/// The preview's own script. It runs in a content world of its own (`PreviewScripts.world`) and
/// only through the app (user scripts and `callAsyncJavaScript`): the page's JavaScript is off.
enum PreviewScripts {
    static let world = WKContentWorld.world(name: "markdown-preview")
    static let handlerName = "md"

    /// Defines `__md` in the world. See `ScrollSync` for the algorithms it mirrors.
    static let source = #"""
    (function () {
      'use strict';
      const post = (m) => { try { window.webkit.messageHandlers.md.postMessage(m); } catch (e) {} };
      let anchors = null, chromeTop = 0, totalLines = 0, lastSet = null, ticking = false, lastPost = 0;
      // The body's HTML as the app sent it (patches are made against it).
      let source = null;
      // The last scroll events: [scrollY, the position the app had set] (diagnostics).
      const scrollLog = [];
      const main = () => document.getElementById('md');

      // Every picture that is not on the web or inline, and every link that is not to the web, goes
      // to the app with its destination exactly as the document wrote it: the app resolves it with
      // the editor's own rules (`..`, `~/`, absolute paths and `file:` included). Done to content
      // that is not in the page yet, so nothing loads from the unrouted address first.
      const web = /^\s*(https?|mailto|tel):/i;
      function route(scope) {
        for (const img of scope.querySelectorAll('img[src]')) {
          const raw = img.getAttribute('src');
          if (/^\s*(https?|data|mdoc):/i.test(raw)) continue;
          img.setAttribute('src', 'mdoc://doc/picture?src=' + encodeURIComponent(raw));
        }
        for (const a of scope.querySelectorAll('a[href]')) {
          const raw = a.getAttribute('href');
          if (raw.startsWith('#') || web.test(raw) || /^\s*mdoc:/i.test(raw)) continue;
          a.setAttribute('href', 'mdoc://doc/link?href=' + encodeURIComponent(raw));
        }
      }
      // The source position at the top of the view, kept while pictures and fonts arrive and the
      // page grows above it (it is what the reader is looking at).
      let readingLine = null;

      function build() {
        const el = main();
        if (!el) return { lines: [], ys: [], startY: 0, endY: 0 };
        const lines = [], ys = [];
        let lastLine = -1, lastY = -Infinity;
        for (const e of el.querySelectorAll('[data-line]')) {
          const line = parseInt(e.getAttribute('data-line'), 10);
          const y = e.getBoundingClientRect().top + window.scrollY - chromeTop;
          if (line > lastLine && y >= lastY) { lines.push(line); ys.push(y); lastLine = line; lastY = y; }
        }
        const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
        const startY = r.top + window.scrollY - chromeTop + parseFloat(cs.paddingTop);
        const endY = r.bottom + window.scrollY - chromeTop - parseFloat(cs.paddingBottom);
        return { lines, ys, startY, endY };
      }
      function table() {
        if (!anchors) anchors = build();
        const a = [];
        if (!anchors.lines.length || anchors.lines[0] > 0) a.push([0, anchors.startY]);
        for (let i = 0; i < anchors.lines.length; i++) a.push([anchors.lines[i], anchors.ys[i]]);
        const last = a[a.length - 1];
        a.push([Math.max(totalLines, last[0] + 1), Math.max(anchors.endY, last[1])]);
        return a;
      }
      function search(a, key, index) {
        let lo = 0, hi = a.length - 1;
        while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (a[mid][index] <= key) lo = mid; else hi = mid; }
        return lo;
      }
      function yForLine(line) {
        const a = table();
        const l = Math.min(Math.max(line, a[0][0]), a[a.length - 1][0]);
        const i = search(a, l, 0), p = a[i], q = a[i + 1];
        return q[0] > p[0] ? p[1] + (l - p[0]) / (q[0] - p[0]) * (q[1] - p[1]) : p[1];
      }
      function lineForY(y) {
        const a = table();
        const v = Math.min(Math.max(y, a[0][1]), a[a.length - 1][1]);
        const i = search(a, v, 1), p = a[i], q = a[i + 1];
        return q[1] > p[1] ? p[0] + (v - p[1]) / (q[1] - p[1]) * (q[0] - p[0]) : p[0];
      }
      function maxScroll() { return Math.max(0, document.documentElement.scrollHeight - window.innerHeight); }
      function setTop(top) {
        const t = Math.min(Math.max(top, 0), maxScroll());
        lastSet = t;
        window.scrollTo(0, t);
        return t;
      }
      function topForLine(line) { return line <= 0.0001 ? 0 : Math.min(Math.max(yForLine(line), 0), maxScroll()); }
      // The page changed size (a picture or a font arrived): the reading position stays put.
      function relayout() {
        anchors = null;
        if (readingLine === null) return;
        const t = topForLine(readingLine);
        if (Math.abs(t - window.scrollY) >= 1) setTop(t);
      }

      window.__md = {
        // Resolves when the page's fonts and pictures are in, or after `ms` (a picture on a server
        // that never answers must not hold up a PDF).
        ready(ms) {
          const waits = [...document.images].filter((i) => !i.complete).map((i) => new Promise((r) => { i.addEventListener('load', r); i.addEventListener('error', r); }));
          const all = Promise.all([document.fonts ? document.fonts.ready : null, ...waits]).then(() => true);
          return Promise.race([all, new Promise((r) => setTimeout(() => r(false), ms || 10000))]);
        },
        replaceBody(html, total) {
          const el = main();
          if (!el) return false;
          const x = window.scrollX, y = window.scrollY;
          const t = document.createElement('template');
          t.innerHTML = html;
          route(t.content);
          el.replaceChildren(t.content);
          source = html;
          totalLines = total;
          anchors = null;
          window.scrollTo(x, y);
          return true;
        },
        // The body by a `BodyPatch` (see the app): false when the page does not hold what the
        // patch was made from (the app then sends the whole body).
        patchBody(start, oldEnd, insert, delta, total, oldLength, newLength) {
          if (source === null || source.length !== oldLength) return false;
          let tail = source.slice(oldEnd);
          if (delta) tail = tail.replace(/data-line="(\d+)"/g, (m, n) => 'data-line="' + (parseInt(n, 10) + delta) + '"');
          const html = source.slice(0, start) + insert + tail;
          if (html.length !== newLength) return false;
          return this.replaceBody(html, total);
        },
        source() { return source; },
        // Tests: what the page's body would hold for `html` sent whole (routed, parsed).
        parsed(html) { const t = document.createElement('template'); t.innerHTML = html; route(t.content); const d = document.createElement('div'); d.append(t.content); return d.innerHTML; },
        prepare(total) { totalLines = total; route(document); anchors = null; return true; },
        setStyle(css) {
          const s = document.head.querySelector('style');
          if (s) s.textContent = css;
          anchors = null;
          return true;
        },
        setFonts(css) {
          let s = document.getElementById('md-fonts');
          if (!s) { s = document.createElement('style'); s.id = 'md-fonts'; document.head.appendChild(s); }
          s.textContent = css;
          return true;
        },
        setChrome(top, bottom) {
          chromeTop = top; anchors = null;
          document.documentElement.style.setProperty('--chrome-top', top + 'px');
          document.documentElement.style.setProperty('--chrome-bottom', bottom + 'px');
          return true;
        },
        scrollToLine(line, onlyIfDrifted) {
          readingLine = line;
          const target = topForLine(line);
          if (onlyIfDrifted && Math.abs(target - window.scrollY) < 3) return window.scrollY;
          return setTop(target);
        },
        currentLine() { return lineForY(window.scrollY); },
        // Keeps the block being typed in on screen.
        revealLine(line) {
          const y = yForLine(line) - window.scrollY;
          if (y >= 0 && y < window.innerHeight - 80) return false;
          setTop(yForLine(line) - window.innerHeight / 3);
          readingLine = lineForY(window.scrollY);
          return true;
        },
        scrollToId(id) {
          const el = document.getElementById(id);
          if (!el) return false;
          el.scrollIntoView({ block: 'start' });
          readingLine = lineForY(window.scrollY);
          return true;
        },
        scrollTop() { return window.scrollY; },
        readingLine() { return readingLine; },
        scrollLog() { return scrollLog.slice(); },
        metrics() { return { height: document.documentElement.scrollHeight, viewport: window.innerHeight, top: window.scrollY, chromeTop }; },
        table() { return table(); },
        yForLine, lineForY,
      };

      let observer = null;
      addEventListener('DOMContentLoaded', () => {
        route(document);
        if (typeof ResizeObserver === 'function' && main()) {
          observer = new ResizeObserver(relayout);
          observer.observe(main());
        }
      });
      addEventListener('resize', () => { anchors = null; });
      addEventListener('scroll', () => {
        // The event for a scroll the app made (one per frame): used up by it, so the reader
        // scrolling back to the same place later is still the reader.
        scrollLog.push([Math.round(window.scrollY), lastSet === null ? null : Math.round(lastSet)]);
        if (scrollLog.length > 50) scrollLog.shift();
        if (lastSet !== null && Math.abs(window.scrollY - lastSet) < 1.5) { lastSet = null; return; }
        lastSet = null;
        // The reader moved: this is now the position to keep.
        readingLine = window.scrollY < 1 ? 0 : lineForY(window.scrollY);
        // At once when quiet (a timer in a page that is not frontmost can wait a second), and a
        // trailing report when scrolling continues.
        const send = () => {
          lastPost = performance.now();
          const top = window.scrollY, max = maxScroll();
          post({ kind: 'scroll', line: top < 1 ? 0 : lineForY(top), top, atEnd: max > 0 && top >= max - 1 });
        };
        const since = performance.now() - lastPost;
        if (since >= 16) { send(); return; }
        if (ticking) return;
        ticking = true;
        setTimeout(() => { ticking = false; send(); }, 16 - since);
      }, { passive: true });
    })();
    """#
}

/// The sizes, in points, of the local pictures a document refers to, for the `width` and `height`
/// the preview's `<img>` elements carry (so the page does not jump as pictures arrive, and a retina
/// screenshot is as big there as in the editor: its points are its pixels over its declared
/// resolution, see `sizes(of:)`). Only a file's header is read, once per
/// modification. Safe to call from any thread.
final class PictureSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [URL: (modified: Date?, size: CGSize?)] = [:]

    func sizes(for destinations: Set<String>, documentURL: URL?) -> [ImageSize] {
        var out: [ImageSize] = []
        for destination in destinations.sorted() {
            // The editor's rule for which file a destination names, and which it may read.
            guard let url = DocumentFileAccess.pictureURL(for: destination, documentURL: documentURL), url.isFileURL,
                  DocumentFileAccess.mayRead(url, documentURL: documentURL) else { continue }
            let modified = DocumentFileAccess.modificationDate(of: url)
            lock.lock()
            let known = cache[url]
            lock.unlock()
            let size: CGSize?
            if let known, known.modified == modified {
                size = known.size
            } else {
                size = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                    .flatMap { Self.sizes(of: $0)?.points }
                lock.lock()
                cache[url] = (modified, size)
                if cache.count > 2_000 { cache.removeAll() }
                lock.unlock()
            }
            if let size, size.width >= 1, size.height >= 1 {
                out.append(ImageSize(destination: destination, width: UInt32(size.width.rounded()), height: UInt32(size.height.rounded())))
            }
        }
        return out
    }

    /// How big a picture is: in pixels, and in points. A file that declares its resolution is
    /// drawn at the size it declares (a retina screenshot is 144 dpi: its points are half its
    /// pixels, as Preview and Finder show it); one that does not, or says 72, is a point per pixel.
    /// Orientation is applied.
    static func sizes(of src: CGImageSource) -> (pixels: CGSize, points: CGSize)? {
        guard CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0
        else { return nil }
        // Only a believable resolution counts (0 and 1 are what some writers put for "unknown").
        func factor(_ key: CFString) -> Double {
            guard let dpi = (props[key] as? NSNumber)?.doubleValue, dpi >= 24, dpi <= 2400 else { return 1 }
            return 72 / dpi
        }
        var pixels = CGSize(width: w, height: h)
        var points = CGSize(width: w * factor(kCGImagePropertyDPIWidth), height: h * factor(kCGImagePropertyDPIHeight))
        if ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 {
            pixels = CGSize(width: pixels.height, height: pixels.width)
            points = CGSize(width: points.height, height: points.width)
        }
        return (pixels, points)
    }
}
