import AppKit
import UniformTypeIdentifiers
import WebKit
import MarkdownCore

/// How a window shows its document: the editor alone, the editor beside the preview, or the
/// preview alone (read-only). Independent of `ViewMode` (Source or Live), which says how the
/// editor itself looks.
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
/// scheme handler (`PreviewSchemeHandler`), never through `file:`:
///
///     mdoc://doc/rel/<path>    a file relative to the document's folder (and below)
///     mdoc://doc/abs/<path>    a file the Markdown names by absolute path or `file:` URL
///     mdoc://doc/home/<path>   a file the Markdown names as `~/path`
///     mdoc://doc/font/<name>   one of the bundled writing fonts
public enum PreviewURL {
    public static let scheme = "mdoc"
    public static let host = "doc"
    public static let base = URL(string: "mdoc://doc/rel/")!

    public enum Resolution: Equatable {
        case file(URL)
        case font(String)
        /// Refused: outside what the document may read.
        case denied
        /// Not one of ours.
        case unknown
    }

    /// Where a request for `url` is served from. `documentFolder` is nil for a document that was
    /// never saved (relative paths then have no base). Relative requests may not climb out of the
    /// document's folder; explicit absolute and `~/` paths are allowed, as the editor allows
    /// them (see `DocumentFileAccess.canReadForPreview`).
    public static func resolve(_ url: URL, documentFolder: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Resolution {
        guard url.scheme == scheme, url.host == host else { return .unknown }
        // Percent-decoded path components, the way the file system will see them.
        let path = url.path(percentEncoded: false)
        func rest(after prefix: String) -> String? { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil }
        if let name = rest(after: "/font/") {
            return .font(name)
        }
        if let relative = rest(after: "/rel/") {
            guard let folder = documentFolder else { return .denied }
            let file = URL(fileURLWithPath: relative, isDirectory: false, relativeTo: URL(fileURLWithPath: folder.standardizedFileURL.path, isDirectory: true)).standardizedFileURL
            return DocumentFileAccess.canReadForPreview(file, documentFolder: folder, explicit: false) ? .file(file) : .denied
        }
        if let absolute = rest(after: "/abs/") {
            let file = URL(fileURLWithPath: "/" + absolute).standardizedFileURL
            return DocumentFileAccess.canReadForPreview(file, documentFolder: documentFolder, explicit: true) ? .file(file) : .denied
        }
        if let underHome = rest(after: "/home/") {
            let file = URL(fileURLWithPath: underHome, isDirectory: false, relativeTo: URL(fileURLWithPath: home.path, isDirectory: true)).standardizedFileURL
            return DocumentFileAccess.canReadForPreview(file, documentFolder: documentFolder, explicit: true) ? .file(file) : .denied
        }
        return .denied
    }

    /// The document folder a relative request is checked against.
    public static func folder(of documentURL: URL?) -> URL? {
        documentURL?.deletingLastPathComponent().standardizedFileURL
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
    /// Do nothing.
    case ignore
}

public enum LinkPolicy {
    /// - `isLinkActivation`: the user clicked a link (a drop, a script or a redirect is not).
    /// - `isMainFrame`: the navigation targets the page, not a frame a document's raw HTML made.
    /// - `isInitialLoad`: the app's own `loadHTMLString` for the page.
    public static func decide(url: URL?, isLinkActivation: Bool, isMainFrame: Bool, isInitialLoad: Bool,
                              documentFolder: URL?) -> LinkAction {
        guard let url else { return .ignore }
        if isInitialLoad, url.scheme == PreviewURL.scheme { return .allow }
        guard isMainFrame, isLinkActivation else { return .ignore }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel":
            return .open(url)
        case PreviewURL.scheme:
            // Relative to the page: a fragment of it, or another file.
            let samePage = url.host == PreviewURL.host && (url.path == "/rel/" || url.path == "/rel")
            if samePage {
                guard let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty else { return .ignore }
                return .scrollToFragment(fragment)
            }
            switch PreviewURL.resolve(url, documentFolder: documentFolder) {
            case .file(let file): return .open(file)
            default: return .ignore
            }
        case "file":
            return .open(url.standardizedFileURL)
        default:
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

// MARK: - serving the preview's files

/// Answers `mdoc://` requests: document-relative and explicitly named files (through
/// `DocumentFileAccess`, the sandbox seam) and the bundled fonts. Replies are made on the main
/// thread; the reading happens on a background queue.
public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The folder relative requests resolve against; nil for an untitled document.
    public var documentFolder: () -> URL? = { nil }
    public var fontDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
    /// Instrumentation: the URLs asked for, and how many were refused.
    public private(set) var requests: [URL] = []
    public private(set) var denied = 0
    public private(set) var failed = 0
    public private(set) var served = 0

    private let queue = DispatchQueue(label: "markdown.preview.files", qos: .userInitiated, attributes: .concurrent)
    private var stopped = Set<ObjectIdentifier>()
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
        let folder = documentFolder()
        let id = ObjectIdentifier(task as AnyObject)
        switch PreviewURL.resolve(url, documentFolder: folder) {
        case .denied, .unknown:
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
        stopped.insert(ObjectIdentifier(task as AnyObject))
    }

    private func load(_ file: URL, for task: any WKURLSchemeTask, id: ObjectIdentifier, url: URL, mime: String) {
        let key = file as NSURL
        let modified = DocumentFileAccess.modificationDate(of: file)
        if let entry = cache.object(forKey: key) as? CacheBox, entry.value.modified == modified, modified != nil {
            reply(task, id: id, url: url, mime: mime, data: entry.value.data)
            return
        }
        queue.async { [weak self] in
            let data = try? DocumentFileAccess.read(file)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data else { self.failed += 1; self.fail(task, id: id, status: 404, url: url); return }
                self.cache.setObject(CacheBox(CacheEntry(data: data, modified: modified)), forKey: key, cost: data.count)
                self.reply(task, id: id, url: url, mime: mime, data: data)
            }
        }
    }

    private final class CacheBox: NSObject {
        let value: CacheEntry
        init(_ v: CacheEntry) { value = v }
    }

    private func reply(_ task: any WKURLSchemeTask, id: ObjectIdentifier, url: URL, mime: String, data: Data) {
        if stopped.remove(id) != nil { return }
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        served += 1
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, id: ObjectIdentifier, status: Int, url: URL) {
        if stopped.remove(id) != nil { return }
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
      const main = () => document.getElementById('md');

      // Absolute paths and `file:` URLs in the Markdown go through the app's scheme (a page cannot
      // read `file:`), `~/` too; relative ones already resolve against the page's address.
      function fixImages(scope) {
        for (const img of scope.querySelectorAll('img')) {
          const raw = img.getAttribute('src');
          if (!raw) continue;
          let to = null;
          if (/^file:/i.test(raw)) to = 'mdoc://doc/abs' + raw.replace(/^file:\/\/(localhost)?/i, '').replace(/^\/*/, '/');
          else if (raw.startsWith('/')) to = 'mdoc://doc/abs' + raw;
          else if (raw.startsWith('~/')) to = 'mdoc://doc/home/' + raw.slice(2);
          if (to) img.setAttribute('src', to);
        }
      }

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

      window.__md = {
        ready() {
          const waits = [...document.images].filter((i) => !i.complete).map((i) => new Promise((r) => { i.onload = i.onerror = r; }));
          return Promise.all([document.fonts ? document.fonts.ready : null, ...waits]).then(() => true);
        },
        replaceBody(html, total) {
          const el = main();
          if (!el) return false;
          const x = window.scrollX, y = window.scrollY;
          const t = document.createElement('template');
          t.innerHTML = html;
          fixImages(t.content);
          el.replaceChildren(t.content);
          totalLines = total;
          anchors = null;
          window.scrollTo(x, y);
          return true;
        },
        prepare(total) { totalLines = total; fixImages(document); anchors = null; return true; },
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
          const target = line <= 0.0001 ? 0 : Math.min(Math.max(yForLine(line), 0), maxScroll());
          if (onlyIfDrifted && Math.abs(target - window.scrollY) < 3) return window.scrollY;
          return setTop(target);
        },
        currentLine() { return lineForY(window.scrollY); },
        // Keeps the block being typed in on screen.
        revealLine(line) {
          const y = yForLine(line) - window.scrollY;
          if (y >= 0 && y < window.innerHeight - 80) return false;
          setTop(yForLine(line) - window.innerHeight / 3);
          return true;
        },
        scrollToId(id) {
          const el = document.getElementById(id);
          if (!el) return false;
          el.scrollIntoView({ block: 'start' });
          return true;
        },
        scrollTop() { return window.scrollY; },
        metrics() { return { height: document.documentElement.scrollHeight, viewport: window.innerHeight, top: window.scrollY, chromeTop }; },
        table() { return table(); },
        yForLine, lineForY,
      };

      let observer = null;
      addEventListener('DOMContentLoaded', () => {
        fixImages(document);
        if (typeof ResizeObserver === 'function' && main()) {
          observer = new ResizeObserver(() => { anchors = null; });
          observer.observe(main());
        }
      });
      addEventListener('resize', () => { anchors = null; });
      addEventListener('scroll', () => {
        if (lastSet !== null && Math.abs(window.scrollY - lastSet) < 1.5) return;
        lastSet = null;
        // At once when quiet (a timer in a page that is not frontmost can wait a second), and a
        // trailing report when scrolling continues.
        const send = () => { lastPost = performance.now(); post({ kind: 'scroll', line: lineForY(window.scrollY), top: window.scrollY }); };
        const since = performance.now() - lastPost;
        if (since >= 16) { send(); return; }
        if (ticking) return;
        ticking = true;
        setTimeout(() => { ticking = false; send(); }, 16 - since);
      }, { passive: true });
    })();
    """#
}
