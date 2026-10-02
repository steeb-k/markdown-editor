#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore
import Network
import WebKit

/// A self-driving mode for checking the real app without Accessibility permissions: the app
/// reads a JSON script, drives itself on the main run loop through the same paths a user
/// would (key events into the window, menu actions through the responder chain, settings),
/// writes PNG snapshots of its own windows and a JSON log of every step and assertion, then
/// quits. Compiled into debug builds, and into release builds only with `-DUI_SCRIPT`
/// (`scripts/macos/bundle.sh --release --ui-script`); it runs only when launched with
/// `--ui-script <script.json>` (output: `--ui-out <dir>`, default `<script dir>/out`).
///
/// A script is a JSON array of steps; each step is an object whose first recognised key is the
/// verb. See `scripts/macos/ui/README.md` for the verbs.
///
/// The harness never touches the user's preferences (it runs on its own defaults suite) and
/// never edits the files it is given (it opens copies).
/// Runs `body` on the main run loop after `delay`. Not through the main dispatch queue: a step
/// that spins the run loop (waiting for styling) from inside a main-queue block would starve
/// every other main-queue block, the analysis results included.
private func later(_ delay: TimeInterval, _ body: @escaping () -> Void) {
    let t = Timer(timeInterval: max(0, delay), repeats: false) { _ in body() }
    RunLoop.main.add(t, forMode: .common)
}

/// Every editor object the script has seen, weakly: what is still alive after documents close.
private let seenObjects = NSHashTable<AnyObject>.weakObjects()

/// Runs on the main run loop, like a person at the keyboard.
@MainActor
final class UIScriptRunner {
    nonisolated static var isRequested: Bool { scriptPath != nil }

    nonisolated private static var scriptPath: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-script"), i + 1 < args.count { return args[i + 1] }
        return ProcessInfo.processInfo.environment["MARKDOWN_UI_SCRIPT"]
    }

    private static var outPath: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-out"), i + 1 < args.count { return args[i + 1] }
        return nil
    }

    /// Defaults for `Settings.shared` while a script runs: a private, emptied suite.
    nonisolated static func scriptDefaults() -> UserDefaults? {
        guard isRequested else { return nil }
        let name = "io.github.steeb-k.Markdown.uiscript"
        let d = UserDefaults(suiteName: name)
        d?.removePersistentDomain(forName: name)
        return d
    }

    private static var running: UIScriptRunner?

    /// Any Objective-C exception ends the script as a failure, at the point it is thrown: it is
    /// logged with its stack (the throw site, which a crash report does not keep), recorded in
    /// `log.json`, and the app exits with status 3. Left to the run loop it would be swallowed
    /// (the script just stops) or, on recent macOS, end in AppKit's exception telltale aborting
    /// the process with a crash report. Set `UI_SCRIPT_EXCEPTIONS=log` to only log them.
    private static func logExceptions() {
        typealias Preprocessor = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias Setter = @convention(c) (Preprocessor) -> Preprocessor?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else { return }
        let set = unsafeBitCast(sym, to: Setter.self)
        _ = set { raw in
            if let raw, let e = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? NSException {
                let stack = Thread.callStackSymbols.prefix(30).joined(separator: "\n")
                let text = "[ui-script] EXCEPTION \(e.name.rawValue): \(e.reason ?? "")\n" + stack + "\n"
                FileHandle.standardError.write(Data(text.utf8))
                if ProcessInfo.processInfo.environment["UI_SCRIPT_EXCEPTIONS"] != "log" {
                    UIScriptRunner.running?.failOnException(e, stack: stack)
                }
            }
            return raw
        }
    }

    private func failOnException(_ e: NSException, stack: String) {
        record(["exception": e.name.rawValue, "reason": e.reason ?? "", "stack": stack], ok: false)
        let summary: [String: Any] = ["steps": steps.count, "failures": failures, "log": log]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("log.json"))
        }
        FileHandle.standardError.write(Data("[ui-script] stopped by an exception in step \(index); log in \(outDir.path)/log.json\n".utf8))
        exit(3)
    }

    /// The last URL a Cmd-click asked to open (nothing is really opened while a script runs).
    private static var opened: URL?
    /// Whether the last `pasteImage` inserted a picture (nil while it waits, e.g. on the save panel).
    private static var pasted: Bool?

    static func startIfRequested() {
        guard let path = scriptPath else { return }
        logExceptions()
        LinkOpener.opened = { url in UIScriptRunner.opened = url; return true }
        let runner = UIScriptRunner(script: URL(fileURLWithPath: path))
        running = runner
        later(0.3) { runner.run() }
    }

    // MARK: state

    private let scriptURL: URL
    private let outDir: URL
    private var steps: [[String: Any]] = []
    private var index = 0
    private var log: [[String: Any]] = []
    private var failures = 0
    private var document: MarkdownDocument?
    private var weakProbes: [(String, () -> AnyObject?)] = []

    private init(script: URL) {
        scriptURL = script
        outDir = UIScriptRunner.outPath.map { URL(fileURLWithPath: $0) }
            ?? script.deletingLastPathComponent().appendingPathComponent("out")
    }

    private var controller: EditorWindowController? { document?.windowControllers.first as? EditorWindowController }
    private var window: NSWindow? { controller?.window }
    private var textView: EditorTextView? { controller?.textView }
    private var session: EditorSession? { document?.session }

    // MARK: running

    private func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        do {
            let data = try Data(contentsOf: scriptURL)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw NSError(domain: "UIScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "a script is a JSON array of objects"])
            }
            steps = array
        } catch {
            record(["error": "cannot read script: \(error)"], ok: false)
            finish()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        next()
    }

    private func next() {
        guard index < steps.count else { finish(); return }
        let step = steps[index]
        index += 1
        if ProcessInfo.processInfo.environment["UI_SCRIPT_TRACE"] != nil {
            FileHandle.standardError.write(Data("[ui-script] begin \(index): \(step)\n".utf8))
        }
        perform(step) { [weak self] in
            // One run-loop turn between steps, so the app reacts like it would to a person.
            later(0) { self?.next() }
        }
    }

    private func record(_ entry: [String: Any], ok: Bool) {
        var e = entry
        e["step"] = index
        e["ok"] = ok
        if !ok { failures += 1 }
        log.append(e)
        let line = (try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(e)"
        FileHandle.standardError.write(Data(("[ui-script] " + line + "\n").utf8))
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        record(["assert": name, "detail": detail], ok: ok)
    }

    private func finish() {
        let summary: [String: Any] = ["steps": steps.count, "failures": failures, "log": log]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("log.json"))
        }
        FileHandle.standardError.write(Data("[ui-script] done: \(failures) failure(s); log in \(outDir.path)/log.json\n".utf8))
        // Quit without the save machinery: everything opened was a scratch copy.
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: steps

    private func perform(_ step: [String: Any], then done: @escaping () -> Void) {
        func str(_ k: String) -> String? { step[k] as? String }
        func num(_ k: String) -> Double? { (step[k] as? NSNumber)?.doubleValue }

        if let path = str("open") {
            open(path, folder: step["folder"] as? Bool ?? false, then: done)
        } else if let mode = str("layout") {
            session?.setLayout(LayoutMode(rawValue: mode) ?? .editor)
            record(["layout": mode], ok: session?.layout.rawValue == mode)
            done()
        } else if step["waitPreview"] != nil {
            let p = controller?.previewController
            let ok = p?.waitUntilSettled(timeout: num("waitPreview") ?? 30) ?? false
            record(["waitPreview": ok, "renders": p?.renders ?? 0, "applied": p?.applied ?? 0, "superseded": p?.superseded ?? 0,
                    "latency_ms": (p?.lastLatency ?? 0) * 1000, "core_render_ms": (p?.lastRenderTime ?? 0) * 1000,
                    "page_update_ms": (p?.lastApplyTime ?? 0) * 1000,
                    "files": ["requests": p?.schemeHandler.requests.map(\.absoluteString).suffix(4) ?? [], "served": p?.schemeHandler.served ?? 0, "denied": p?.schemeHandler.denied ?? 0, "failed": p?.schemeHandler.failed ?? 0]], ok: ok)
            done()
        } else if let js = str("evalPreview") {
            let r = controller?.previewController.evaluateSync(js)
            record(["evalPreview": "\(String(describing: r))"], ok: true)
            done()
        } else if let name = str("exportPDF") {
            exportPDF(name, then: done)
        } else if let kind = str("copyAs") {
            let pb = scriptPasteboard()
            let ok = pb.map { session?.copyAs(kind == "html" ? .html : .richText, range: textView?.selectedRange() ?? NSRange(location: 0, length: 0), to: $0) ?? false } ?? false
            record(["copyAs": kind, "types": pb?.types?.map(\.rawValue) ?? []], ok: ok)
            done()
        } else if let f = (step["previewScroll"] as? NSNumber)?.doubleValue {
            // Scrolls the preview the way a person would (its own scroll event is the user's).
            let p = controller?.previewController
            // The page's own scroll event waits for a rendering update, which WebKit holds back
            // for a window it thinks hidden: it is sent at once, as that update would.
            _ = p?.evaluateSync("const m = Math.max(0, document.documentElement.scrollHeight - window.innerHeight); window.scrollTo(0, m * f); window.dispatchEvent(new Event('scroll')); return m;", arguments: ["f": f])
            record(["previewScroll": f], ok: p != nil)
            later(0.3, done)
        } else if let f = (step["editorScroll"] as? NSNumber)?.doubleValue {
            if let tv = textView, let sv = tv.enclosingScrollView {
                let clip = sv.contentView
                let top = -sv.contentInsets.top
                let range = max(0, tv.frame.height - clip.bounds.height + sv.contentInsets.bottom - top)
                clip.scroll(to: NSPoint(x: 0, y: top + range * CGFloat(f)))
                sv.reflectScrolledClipView(clip)
            }
            record(["editorScroll": f], ok: textView != nil)
            later(0.3, done)
        } else if let needle = str("clickPreviewLink") {
            // A click on the link whose text contains `needle`, in the page (the policy decides what happens).
            let p = controller?.previewController
            let found = p?.evaluateSync("const a = [...document.querySelectorAll('a')].find(x => x.textContent.includes(needle)); if (!a) return false; a.click(); return true;", arguments: ["needle": needle]) as? Bool
            record(["clickPreviewLink": needle, "found": found ?? false, "action": "\(String(describing: p?.lastLinkAction))"], ok: found == true)
            later(0.3, done)
        } else if let m = step["measurePreview"] as? [String: Any] {
            measurePreview(m, then: done)
        } else if let mode = str("viewMode") {
            session?.setViewMode(ViewMode(rawValue: mode) ?? .source)
            record(["viewMode": mode], ok: session?.viewMode.rawValue == mode)
            done()
        } else if let f = step["focus"] as? [String: Any] {
            if let scope = f["scope"] as? String, let c = FocusScopeChoice(rawValue: scope) { Settings.shared.focusScope = c }
            if let on = f["on"] as? Bool { session?.setFocusEnabled(on) }
            session?.refreshState(synchronous: true)
            record(["focus": f], ok: session != nil)
            done()
        } else if let f = step["syntax"] as? [String: Any] {
            if let classes = f["classes"] as? [String] {
                for c in SyntaxClass.allCases { Settings.shared.setSyntaxClass(c, classes.contains(c.rawValue)) }
            }
            if let on = f["on"] as? Bool { session?.setSyntaxEnabled(on) }
            record(["syntax": f], ok: session != nil)
            done()
        } else if step["waitSyntax"] != nil {
            let ok = session?.pos.waitUntilSettled(timeout: num("waitSyntax") ?? 30) ?? false
            record(["waitSyntax": ok, "tagged units": session?.pos.taggerInvocations ?? 0], ok: ok)
            done()
        } else if let n = step["clickCheckbox"] as? Int {
            var ok = false
            if let tv = textView, let lm = tv.layoutManager as? EditorLayoutManager, let tc = tv.textContainer {
                let boxes = lm.live.decorations.filter { if case .checkbox = $0.kind { return true } else { return false } }
                if n < boxes.count, let f = lm.checkboxFrame(of: boxes[n], in: tc) {
                    let o = tv.textContainerOrigin
                    ok = tv.handleCheckboxClick(at: NSPoint(x: f.midX + o.x, y: f.midY + o.y))
                }
            }
            record(["clickCheckbox": n], ok: ok)
            done()
        } else if let needle = str("cmdClickLink") {
            var ok = false
            if let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer {
                let r = ((session?.text ?? "") as NSString).range(of: needle)
                if r.location != NSNotFound {
                    let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: 1), actualCharacterRange: nil)
                    let b = lm.boundingRect(forGlyphRange: g, in: tc)
                    let o = tv.textContainerOrigin
                    ok = tv.openLink(at: NSPoint(x: b.midX + o.x, y: b.midY + o.y))
                }
            }
            record(["cmdClickLink": needle, "opened": Self.opened.map { $0.absoluteString }], ok: ok)
            done()
        } else if let dir = str("httpServe") {
            // A tiny local web server for remote pictures (no internet needed).
            let port = (step["port"] as? Int) ?? 8765
            let ok = LocalHTTPServer.start(root: resolve(dir), port: UInt16(port))
            record(["httpServe": dir, "port": port], ok: ok)
            later(0.2, done)
        } else if let c = step["copyFile"] as? [String: String], let from = c["from"], let to = c["to"] {
            // `to` is relative to the output directory (the opened copies live in `work/`).
            let dst = outDir.appendingPathComponent(to)
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            let ok = (try? FileManager.default.copyItem(at: resolve(from), to: dst)) != nil
            record(["copyFile": c], ok: ok)
            done()
        } else if step["revalidateImages"] != nil {
            // What the window becoming key again does.
            session?.imageController.revalidate()
            record(["revalidateImages": true], ok: true)
            later(0.5, done)
        } else if let path = str("pasteImage") {
            // Image data on a private pasteboard, pasted the way Edit > Paste does it.
            let pb = NSPasteboard(name: NSPasteboard.Name("markdown-ui-script-\(UUID().uuidString)"))
            pb.clearContents()
            pb.setData(try? Data(contentsOf: resolve(path)), forType: .png)
            Self.pasted = nil
            textView?.pasteImage(from: pb) { ok in Self.pasted = ok }
            let deadline = Date(timeIntervalSinceNow: (step["wait"] as? Double) ?? 3)
            func poll() {
                if Self.pasted == nil && Date() < deadline { later(0.05, poll); return }
                pb.releaseGlobally()
                record(["pasteImage": path, "inserted": Self.pasted.map { "\($0)" } ?? "pending"], ok: true)
                done()
            }
            poll()
        } else if let path = str("dropFile") {
            let pb = NSPasteboard(name: NSPasteboard.Name("markdown-ui-script-\(UUID().uuidString)"))
            pb.clearContents()
            pb.writeObjects([resolve(path) as NSURL])
            let ok = textView?.handleDrop(pb, at: textView?.selectedRange().location ?? 0) ?? false
            pb.releaseGlobally()
            record(["dropFile": path], ok: ok)
            done()
        } else if let w = num("waitImages") {
            let deadline = Date(timeIntervalSinceNow: w)
            func poll() {
                if (session?.imageController.isLoading ?? false) && Date() < deadline { later(0.05, poll) } else { later(0.2, done) }
            }
            record(["waitImages": w], ok: true)
            poll()
        } else if let g = step["openGenerated"] as? [String: Any], let from = g["from"] as? String {
            // A big document: `from` repeated until it is at least `minLength` UTF-16 units.
            let unit = (try? String(contentsOf: resolve(from), encoding: .utf8)) ?? "x\n"
            let target = g["minLength"] as? Int ?? 1_000_000
            var text = ""
            while (text as NSString).length < target { text += unit + "\n" }
            let url = outDir.appendingPathComponent("generated-\(target).md")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            open(url.path, then: done)
        } else if step["new"] != nil {
            document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) as? MarkdownDocument
            record(["new": true], ok: document != nil)
            done()
        } else if let text = str("load") {
            session?.load(text)
            record(["load": (text as NSString).length], ok: true)
            done()
        } else if let text = str("type") {
            type(text, interval: num("interval") ?? 0, then: done)
        } else if let k = step["key"] as? [String: Any] {
            key(k)
            record(["key": k], ok: true)
            done()
        } else if let sel = step["select"] as? [Int], sel.count == 2 {
            document?.undoManager?.groupsByEvent = false
            textView?.setSelectedRange(NSRange(location: sel[0], length: sel[1]))
            record(["select": sel], ok: true)
            done()
        } else if let needle = str("selectText") {
            let r = ((session?.text ?? "") as NSString).range(of: needle)
            let ok = r.location != NSNotFound
            if ok {
                let offset = step["offset"] as? Int
                let length = step["length"] as? Int
                let loc = r.location + (offset ?? 0)
                textView?.setSelectedRange(NSRange(location: loc, length: length ?? (offset == nil ? r.length : 0)))
                textView?.scrollRangeToVisible(NSRange(location: loc, length: 0))
            }
            record(["selectText": needle], ok: ok)
            done()
        } else if let action = str("action") {
            let sender = NSMenuItem()
            sender.tag = step["tag"] as? Int ?? 0
            let sel = Selector(action)
            var ok = false
            let send = {
                ok = NSApp.sendAction(sel, to: nil, from: sender)
                if !ok, let tv = self.textView, tv.responds(to: sel) { ok = NSApp.sendAction(sel, to: tv, from: sender) }
            }
            // An action that edits runs as one undo group, like an event would. One that does not
            // (`"edits": false`: view toggles) must not: a closed empty group marks the document edited.
            if step["edits"] as? Bool == false { send() } else { asEvent(send) }
            record(["action": action], ok: ok)
            done()
        } else if let command = str("command") {
            let run: () -> Void = { self.textView?.doCommand(by: Selector(command)) }
            if step["edits"] as? Bool == false { run() } else { asEvent(run) }
            record(["command": command], ok: textView != nil)
            done()
        } else if let s = step["setting"] as? [String: Any] {
            applySettings(s)
            record(["setting": s], ok: true)
            done()
        } else if let a = str("appearance") {
            NSApp.appearance = a == "system" ? nil : NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
            record(["appearance": a], ok: true)
            done()
        } else if let t = num("wait") {
            later(t, done)
        } else if step["waitStyled"] != nil {
            let ok = session?.waitUntilStyled(timeout: num("waitStyled") ?? 30) ?? false
            record(["waitStyled": ok], ok: ok)
            done()
        } else if let name = str("snapshot") {
            snapshot(name, which: str("window"), bitmap: step["bitmap"] as? Bool ?? false, then: done)
        } else if let a = step["assert"] as? [String: Any] {
            assertions(a)
            done()
        } else if let size = step["resize"] as? [Double], size.count == 2, let w = window {
            var f = w.frame
            f.origin.y += f.height - size[1]
            f.size = NSSize(width: size[0], height: size[1])
            w.setFrame(f, display: true)
            record(["resize": size], ok: true)
            done()
        } else if let on = step["fullscreen"] as? Bool, let w = window, !NSApp.isActive {
            // Full screen needs an active app; a script launched while the session is locked
            // or another app is frontmost cannot get there.
            record(["fullscreen": on, "skipped": "the app is not active"], ok: true)
            done()
        } else if let on = step["fullscreen"] as? Bool, let w = window {
            if w.styleMask.contains(.fullScreen) != on { w.toggleFullScreen(nil) }
            // The transition animates; give it time.
            later(1.5) {
                self.check("fullscreen \(on)", w.styleMask.contains(.fullScreen) == on)
                done()
            }
        } else if step["newTab"] != nil, let c = controller {
            let before = NSDocumentController.shared.documents.count
            c.newWindowForTab(nil)
            let docs = NSDocumentController.shared.documents
            if let d = docs.last as? MarkdownDocument, docs.count > before { document = d }
            record(["newTab": window?.tabbedWindows?.count ?? 0], ok: docs.count > before)
            done()
        } else if let to = step["switchTo"] as? Int {
            let docs = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
            if to < docs.count { document = docs[to]; window?.makeKeyAndOrderFront(nil) }
            record(["switchTo": to], ok: to < docs.count)
            done()
        } else if let where_ = step["scroll"] {
            scroll(where_)
            record(["scroll": "\(where_)"], ok: true)
            done()
        } else if str("pointer") != nil {
            controller?.simulatePointerMoved()
            record(["pointer": "moved"], ok: true)
            done()
        } else if let w = str("settingsWindow") {
            if w == "show" { SettingsWindowController.shared.show() } else { SettingsWindowController.shared.close() }
            record(["settingsWindow": w], ok: true)
            done()
        } else if let sheet = str("sheet") {
            // "end": dismiss whatever sheet is attached (Cancel).
            if sheet == "end", let w = window, let s = w.attachedSheet {
                w.endSheet(s, returnCode: .alertSecondButtonReturn)
            }
            record(["sheet": sheet], ok: true)
            done()
        } else if let text = str("setPasteboard") {
            // The window's private pasteboard (never the user's): what Paste and Paste As read.
            let pb = scriptPasteboard()
            pb?.clearContents()
            pb?.setString(text, forType: .string)
            record(["setPasteboard": (text as NSString).length], ok: pb != nil)
            done()
        } else if let which = str("copyOrCut") {
            let tv = textView
            asEvent { if which == "cut" { tv?.cut(nil) } else { tv?.copy(nil) } }
            record(["copyOrCut": which, "authorshipOnPasteboard": scriptPasteboard()?.data(forType: AuthorshipPasteboard.type) != nil], ok: tv != nil)
            done()
        } else if let m = step["markEvery"] as? [String: Any] {
            // Marks `length` characters every `stride` characters (thousands of runs, quickly).
            let stride = m["stride"] as? Int ?? 300, length = m["length"] as? Int ?? 100
            let choice: AuthorChoice = (m["as"] as? String) == "reference" ? .reference : .ai
            var n = 0
            if let s = session {
                let ns = s.text as NSString
                var at = 0
                while at + length < ns.length {
                    let r = ns.rangeOfComposedCharacterSequences(for: NSRange(location: at, length: length))
                    s.authorship.mark(range: r.utf16Range, author: s.author(for: n % 3 == 2 ? .reference : choice))
                    n += 1
                    at += stride
                }
                s.refreshAuthorshipOverlay()
            }
            record(["markEvery": n, "runs": session?.authorship.runs(within: nil).count ?? 0], ok: session != nil)
            done()
        } else if let m = step["soak"] as? [String: Any] {
            soak(m, then: done)
        } else if let on = step["authorshipDisplay"] as? Bool {
            session?.setAuthorshipDisplay(on)
            record(["authorshipDisplay": on], ok: session != nil)
            done()
        } else if let d = str("authorshipDecision") {
            // The keep-or-discard sheet: shown, then answered through its buttons.
            let ok: Bool
            if let w = window, let c = controller {
                c.presentAuthorshipSheetIfNeeded()
                if let sheet = w.attachedSheet {
                    w.endSheet(sheet, returnCode: d == "keep" ? .alertFirstButtonReturn : .alertSecondButtonReturn)
                    ok = true
                } else { ok = false }
            } else { ok = false }
            record(["authorshipDecision": d], ok: ok)
            later(0.2, done)
        } else if step["measureSave"] != nil {
            // A save through NSDocument, timed: how long it took and the longest the main thread
            // was unavailable meanwhile (a 1 ms heartbeat's longest gap).
            guard let doc = document, let url = doc.fileURL else { record(["measureSave": "no file"], ok: false); done(); return }
            var gaps: [Double] = []
            var last = CFAbsoluteTimeGetCurrent()
            let heartbeat = Timer(timeInterval: 0.001, repeats: true) { _ in
                let now = CFAbsoluteTimeGetCurrent()
                gaps.append(now - last)
                last = now
            }
            RunLoop.main.add(heartbeat, forMode: .common)
            let t0 = CFAbsoluteTimeGetCurrent()
            doc.updateChangeCount(.changeDone)
            doc.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { error in
                let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                later(0.05) {
                    heartbeat.invalidate()
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    self.record(["measureSave": ["total_ms": total, "max_runloop_gap_ms": (gaps.max() ?? 0) * 1000, "bytes": bytes,
                                                 "off_main": doc.writesOnMainThread.last == false],
                                 "error": error.map { "\($0)" } ?? ""], ok: error == nil)
                    done()
                }
            }
        } else if step["save"] != nil {
            // Writes the document to its (scratch) file, through the same path Save uses.
            guard let doc = document, let url = doc.fileURL else { record(["save": "no file"], ok: false); done(); return }
            doc.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { error in
                self.record(["save": url.lastPathComponent, "error": error.map { "\($0)" } ?? ""], ok: error == nil)
                done()
            }
        } else if step["reopen"] != nil {
            // Closes the document and opens its file afresh: what quitting and opening again does.
            guard let doc = document, let url = doc.fileURL else { record(["reopen": "no file"], ok: false); done(); return }
            document = nil
            doc.updateChangeCount(.changeCleared)
            doc.close()
            later(0.3) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { d, _, error in
                    self.document = d as? MarkdownDocument
                    self.record(["reopen": url.lastPathComponent, "error": error.map { "\($0)" } ?? ""], ok: self.document != nil)
                    self.window?.makeKeyAndOrderFront(nil)
                    done()
                }
            }
        } else if let needle = str("undoUntilLacks") {
            // Undo steps (typing may take several) until the text no longer holds `needle`.
            var n = 0
            while (session?.text ?? "").contains(needle), document?.undoManager?.canUndo == true, n < 60 { document?.undoManager?.undo(); n += 1 }
            record(["undoUntilLacks": needle, "steps": n], ok: !(session?.text ?? "").contains(needle))
            done()
        } else if let needle = str("undoUntilContains") {
            var n = 0
            while !(session?.text ?? "").contains(needle), document?.undoManager?.canUndo == true, n < 60 { document?.undoManager?.undo(); n += 1 }
            record(["undoUntilContains": needle, "steps": n], ok: (session?.text ?? "").contains(needle))
            done()
        } else if let needle = str("redoUntilContains") {
            var n = 0
            while !(session?.text ?? "").contains(needle), document?.undoManager?.canRedo == true, n < 60 { document?.undoManager?.redo(); n += 1 }
            record(["redoUntilContains": needle, "steps": n], ok: (session?.text ?? "").contains(needle))
            done()
        } else if step["undo"] != nil {
            document?.undoManager?.undo()
            record(["undo": true], ok: true)
            done()
        } else if step["redo"] != nil {
            document?.undoManager?.redo()
            record(["redo": true], ok: true)
            done()
        } else if let m = step["measureTyping"] as? [String: Any] {
            measureTyping(m, then: done)
        } else if let m = step["measureCaret"] as? [String: Any] {
            measureCaret(m, then: done)
        } else if let m = step["caretWalk"] as? [String: Any] {
            caretWalk(m, then: done)
        } else if let m = step["measureKeys"] as? [String: Any] {
            measureKeys(m, then: done)
        } else if let m = step["measureJump"] as? [String: Any] {
            measureJump(m, then: done)
        } else if step["close"] != nil {
            close(then: done)
        } else if step["controlLeakProbe"] != nil {
            // The same check on a plain AppKit window with a plain text view, as a baseline.
            weak var w: NSWindow?
            weak var t: NSTextView?
            autoreleasepool {
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                let sv = NSScrollView(frame: win.contentView!.bounds)
                let tv = NSTextView(frame: sv.bounds)
                sv.documentView = tv
                win.contentView = sv
                win.makeKeyAndOrderFront(nil)
                (sv.documentView as? NSTextView)?.string = "hello"
                win.makeFirstResponder(sv.documentView)
                win.close()
                w = win
                t = sv.documentView as? NSTextView
            }
            later(2.0) {
                self.record(["controlLeakProbe": "plain window freed \(w == nil), plain text view freed \(t == nil)"], ok: true)
                done()
            }
        } else if step["dump"] != nil {
            var d: [String: Any] = [:]
            if let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let s = session {
                d["textViewFrame"] = NSStringFromRect(tv.frame)
                d["visibleRect"] = NSStringFromRect(tv.visibleRect)
                d["containerSize"] = NSStringFromSize(tc.size)
                d["inset"] = NSStringFromSize(tv.textContainerInset)
                d["usedRect"] = NSStringFromRect(lm.usedRect(for: tc))
                d["length"] = s.storage.length
                d["owed"] = s.owedStyling.map { NSStringFromRange($0) }
                d["styled"] = s.isStyled
                d["idle"] = s.coordinator.isIdle
                d["clipFrame"] = NSStringFromRect(tv.enclosingScrollView?.contentView.frame ?? .zero)
                d["undoGroupingLevel"] = document?.undoManager?.groupingLevel ?? -1
                d["undoActionName"] = document?.undoManager?.undoActionName ?? ""
                d["edited"] = document?.isDocumentEdited ?? false
                d["unautosaved"] = document?.hasUnautosavedChanges ?? false
                d["appActive"] = NSApp.isActive
                d["windowKey"] = window?.isKeyWindow ?? false
                d["titlebarHidden"] = controller?.titlebarControls.map { "\(Swift.type(of: $0)) hidden=\($0.isHidden) alpha=\($0.alphaValue)" } ?? []
                d["scrollFrame"] = NSStringFromRect(tv.enclosingScrollView?.frame ?? .zero)
                d["splitFrame"] = NSStringFromRect(controller?.splitView.frame ?? .zero)
                d["previewPaneFrame"] = NSStringFromRect(controller?.previewPane.frame ?? .zero)
                d["webFrame"] = NSStringFromRect(controller?.previewController.webView.frame ?? .zero)
                d["contentFrame"] = NSStringFromRect(window?.contentView?.frame ?? .zero)
                if s.storage.length > 0 {
                    let a = s.storage.attributes(at: min(40, s.storage.length - 1), effectiveRange: nil)
                    d["attrs40"] = a.map { "\($0.key.rawValue)=\($0.value)" }.sorted()
                }
            }
            record(["dump": d], ok: true)
            done()
        } else if let needle = str("dumpLayout") {
            var out: [String] = []
            if let s = session, let lm = textView?.layoutManager {
                let ns = s.text as NSString
                let r = ns.range(of: needle)
                if r.location != NSNotFound {
                    let para = ns.paragraphRange(for: r)
                    let g = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
                    lm.enumerateLineFragments(forGlyphRange: g) { rect, used, _, fg, _ in
                        var items: [String] = []
                        for gi in fg.location..<NSMaxRange(fg) {
                            let ci = lm.characterIndexForGlyph(at: gi)
                            let p = lm.location(forGlyphAt: gi)
                            let n = lm.propertyForGlyph(at: gi).contains(.null) ? "N" : (lm.propertyForGlyph(at: gi).contains(.controlCharacter) ? "C" : "")
                            items.append("\(ns.substring(with: NSRange(location: ci, length: 1)))@\(Int(p.x))\(n)")
                        }
                        out.append("y=\(Int(rect.minY)) h=\(Int(rect.height)) used=\(NSStringFromRect(used)) " + items.joined(separator: " "))
                    }
                }
            }
            record(["dumpLayout": out], ok: !out.isEmpty)
            done()
        } else if let msg = str("log") {
            record(["log": msg], ok: true)
            done()
        } else {
            record(["unknown step": "\(step)"], ok: false)
            done()
        }
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-root"), i + 1 < args.count {
            let u = URL(fileURLWithPath: args[i + 1]).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        // Relative to the repository when the script lives in it, else to the script.
        var dir = scriptURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return scriptURL.deletingLastPathComponent().appendingPathComponent(path)
    }

    private func open(_ path: String, folder: Bool = false, then done: @escaping () -> Void) {
        let src = resolve(path)
        let work = outDir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        if folder {
            // Images and other files the document refers to by relative path.
            let dir = src.deletingLastPathComponent()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") && name != src.lastPathComponent {
                let dst = work.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: dst)
            }
        }
        do {
            try FileManager.default.copyItem(at: src, to: copy)
        } catch {
            record(["open": path, "error": "\(error)"], ok: false)
            done()
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { doc, _, error in
            self.document = doc as? MarkdownDocument
            self.record(["open": path, "error": error.map { "\($0)" } ?? ""], ok: self.document != nil)
            self.window?.makeKeyAndOrderFront(nil)
            done()
        }
    }

    /// A private pasteboard for the current window, so scripts never touch the user's clipboard.
    private func scriptPasteboard() -> NSPasteboard? {
        guard let tv = textView else { return nil }
        if tv.pasteboard === NSPasteboard.general {
            tv.pasteboard = NSPasteboard(name: NSPasteboard.Name("markdown-ui-script-\(UUID().uuidString)"))
        }
        return tv.pasteboard
    }

    private func applySettings(_ s: [String: Any]) {
        let st = Settings.shared
        if let v = s["theme"] as? String, let t = ThemeChoice(rawValue: v) { st.theme = t }
        if let v = s["fontChoice"] as? String, let f = FontChoice(rawValue: v) { st.fontChoice = f }
        if let v = s["customFontFamily"] as? String { st.customFontFamily = v }
        if let v = s["fontSize"] as? Double { st.fontSize = v }
        if let v = s["lineWidth"] as? Int { st.lineWidth = v }
        if let v = s["spellCheck"] as? Bool { st.spellCheck = v }
        if let v = s["showFormattingToolbar"] as? Bool { st.showFormattingToolbar = v }
        if let v = s["autoHideChrome"] as? Bool { st.autoHideChrome = v }
        if let v = s["defaultViewMode"] as? String, let m = ViewMode(rawValue: v) { st.defaultViewMode = m }
        if let v = s["focusMode"] as? Bool { st.focusMode = v }
        if let v = s["focusScope"] as? String, let m = FocusScopeChoice(rawValue: v) { st.focusScope = m }
        if let v = s["syntaxHighlight"] as? Bool { st.syntaxHighlight = v }
        if let v = s["authorshipDisplay"] as? Bool { st.authorshipDisplay = v }
        if let v = s["authorName"] as? String { st.authorNameSetting = v }
    }

    // MARK: input

    private static let keyCodes: [Character: UInt16] = ["\r": 36, "\n": 36, "\t": 48, "\u{7F}": 51, " ": 49]

    /// A key down and up, sent to the window like the window server would.
    private func sendKey(_ chars: String, mods: NSEvent.ModifierFlags = [], code: UInt16? = nil) {
        guard let w = window else { return }
        let c = chars == "\n" ? "\r" : chars
        let kc = code ?? chars.first.flatMap { Self.keyCodes[$0] } ?? 0
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                           context: nil, characters: c, charactersIgnoringModifiers: c,
                                           isARepeat: false, keyCode: kc) else { continue }
            asEvent {
                if type == .keyDown, mods.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
                w.sendEvent(e)
            }
        }
    }

    /// What `NSApplication` does around each event it dispatches, which events sent straight to
    /// a window (or actions sent from a timer) never get: one undo group per event, so undo
    /// steps and the document's edited state are real. The harness turns grouping-by-event off
    /// for its documents (AppKit's own end-of-event bookkeeping would otherwise trip over it).
    private func asEvent(_ body: () -> Void) {
        guard let um = document?.undoManager else { body(); return }
        um.groupsByEvent = false
        um.beginUndoGrouping()
        body()
        if um.groupingLevel > 0 { um.endUndoGrouping() }
    }

    private func key(_ k: [String: Any]) {
        var mods: NSEvent.ModifierFlags = []
        for m in (k["mods"] as? [String]) ?? [] {
            switch m {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "option": mods.insert(.option)
            case "control": mods.insert(.control)
            default: break
            }
        }
        let code = (k["code"] as? NSNumber)?.uint16Value
        sendKey(k["chars"] as? String ?? "", mods: mods, code: code)
    }

    private func type(_ text: String, interval: Double, then done: @escaping () -> Void) {
        let chars = Array(text)
        var i = 0
        func step() {
            guard i < chars.count else {
                record(["type": text], ok: true)
                done()
                return
            }
            let c = chars[i]
            i += 1
            if c == "\t" { sendKey("\t") } else if c == "⇤" { sendKey("\u{19}", mods: .shift, code: 48) } else { sendKey(String(c)) }
            later(interval, step)
        }
        step()
    }

    private func scroll(_ where_: Any) {
        guard let tv = textView else { return }
        if let s = where_ as? String {
            let len = (session?.text as NSString?)?.length ?? 0
            tv.scrollRangeToVisible(NSRange(location: s == "end" ? len : 0, length: 0))
        } else if let y = (where_ as? NSNumber)?.doubleValue, let clip = tv.enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: 0, y: y))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    // MARK: measuring

    /// Types `count` characters at `interval` seconds into the current document and records how
    /// long the main thread was busy per keystroke, and the longest gap between heartbeats of a
    /// 1 ms timer (any stall shows up there, whatever caused it).
    private func measureTyping(_ m: [String: Any], then done: @escaping () -> Void) {
        let count = m["count"] as? Int ?? 100
        let interval = (m["interval"] as? NSNumber)?.doubleValue ?? 0.05
        var perKey: [Double] = []
        var gaps: [Double] = []
        var last = CFAbsoluteTimeGetCurrent()
        let heartbeat = Timer(timeInterval: 0.001, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            gaps.append(now - last)
            last = now
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        var i = 0
        let alphabet = Array("the quick brown fox jumps over the lazy dog ")
        let wait0 = session?.coordinator.totalWaitTime ?? 0, style0 = session?.totalStyleTime ?? 0
        let state0 = session?.timeInStateQueries ?? 0, pos0 = session?.pos.timeOnMain ?? 0
        let overlayEdit0 = session?.overlay.timeFollowingEdits ?? 0, overlayApply0 = session?.overlay.timeApplying ?? 0
        func step() {
            guard i < count else {
                heartbeat.invalidate()
                let sorted = perKey.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
                let maxGap = (gaps.max() ?? 0) * 1000
                let stats: [String: Any] = [
                    "keystrokes": count, "p50_ms": pct(0.5), "p99_ms": pct(0.99), "max_ms": (sorted.last ?? 0) * 1000,
                    "max_runloop_gap_ms": maxGap, "bound_ms": AnalysisCoordinator.defaultSyncWait * 1000,
                    "mean_wait_ms": ((session?.coordinator.totalWaitTime ?? 0) - wait0) / Double(count) * 1000,
                    "mean_style_ms": ((session?.totalStyleTime ?? 0) - style0) / Double(count) * 1000,
                    "mean_ms": perKey.reduce(0, +) / Double(max(1, perKey.count)) * 1000,
                    "longest_style_ms": (session?.longestStyle ?? 0) * 1000,
                    "mean_state_query_ms": ((session?.timeInStateQueries ?? 0) - state0) / Double(count) * 1000,
                    "mean_pos_main_ms": ((session?.pos.timeOnMain ?? 0) - pos0) / Double(count) * 1000,
                    "mean_overlay_edit_ms": ((session?.overlay.timeFollowingEdits ?? 0) - overlayEdit0) / Double(count) * 1000,
                    "mean_overlay_apply_ms": ((session?.overlay.timeApplying ?? 0) - overlayApply0) / Double(count) * 1000,
                ]
                let limit = (m["maxMs"] as? NSNumber)?.doubleValue
                record(["measureTyping": stats], ok: limit.map { (sorted.last ?? 0) * 1000 <= $0 } ?? true)
                done()
                return
            }
            let c = String(alphabet[i % alphabet.count])
            i += 1
            let t0 = CFAbsoluteTimeGetCurrent()
            sendKey(c)
            perKey.append(CFAbsoluteTimeGetCurrent() - t0)
            later(interval, step)
        }
        step()
    }

    /// Everything together, at random, through the paths a person uses: typing (key events),
    /// Return and Backspace, Paste As and Mark As (menu actions), undo and redo, caret moves and
    /// scrolling, Source and Live, themes, focus mode, syntax highlighting and the authorship
    /// display switched on and off. After every step, once styling and tagging have settled:
    /// the core's text is the storage's, every character's temporary colour is what the layers
    /// say (outside the overlay's window: nothing), the layers are what their sources say (the
    /// attribution, the core's focus range), the runs are valid; every `fileEvery` steps the file
    /// the document would write reads back to the same attribution. Records the main-thread time
    /// of each kind of step.
    private func soak(_ m: [String: Any], then done: @escaping () -> Void) {
        let steps = m["steps"] as? Int ?? 200
        let fileEvery = m["fileEvery"] as? Int ?? 20
        let toggles = m["toggles"] as? Bool ?? true
        var state = UInt64(m["seed"] as? Int ?? 1) &+ 0x9E37_79B9_7F4A_7C15
        func rnd() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var times: [String: [Double]] = [:]
        var opLog: [String] = []
        var failed = 0
        var i = 0
        let words = ["word ", "the ", "\u{1F600} ", "e\u{301}t\u{E9} ", "**b** ", "Sentence. ", "\u{65E5}\u{672C} "]
        let pastes = ["Generated text. Two sentences.", "- a list\n- of items\n", "A quote \u{1F389} from a book."]
        func fail(_ what: String) {
            failed += 1
            if failed <= 10 { check("soak step \(i): \(what) after \(opLog.suffix(4))", false) }
        }
        func verify() {
            guard let s = session, let tv = textView, let lm = tv.layoutManager else { return fail("no document") }
            if s.coordinator.coreText() != s.text { fail("core text differs from the storage") }
            let length = s.storage.length
            // Runs valid.
            let runs = s.authorship.runs(within: nil)
            var prev = 0
            for r in runs {
                if Int(r.range.start) < prev || r.range.end <= r.range.start || Int(r.range.end) > length { fail("invalid run \(r.range)"); break }
                prev = Int(r.range.end)
            }
            // The layers are what their sources say.
            let o = s.overlay
            o.apply()
            let authors = s.authorship.authors()
            var want: [OverlayRun] = []
            if s.authorshipDisplay {
                for r in runs where r.authorIndex != 0 {
                    want.append(OverlayRun(r.range.nsRange, .authorship(authors[Int(r.authorIndex)].kind == .ai ? .ai : .reference)))
                }
            }
            if o.layers.authorship != OverlayCompositor.merged(want) { fail("the authorship layer is not the attribution") }
            if s.focusEnabled {
                let sel = tv.selectedRange()
                let w = s.liveQueryWindow()
                let scope: FocusScope = s.settings.focusScope == .sentence ? .sentence : .paragraph
                let core = s.coordinator.sync { doc in
                    doc.focusRange(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))), scope: scope).map(\.nsRange)
                }
                func clip(_ rs: [NSRange]) -> [NSRange] { rs.map { NSIntersectionRange($0, w) }.filter { $0.length > 0 } }
                if clip(o.layers.focus ?? []) != clip(core) {
                    let u = Utf16Range(start: UInt32(w.location), end: UInt32(NSMaxRange(w)))
                    let windowed = s.coordinator.sync { doc in
                        doc.selectionState(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))), within: u, conceal: false, focus: scope).focus?.map(\.nsRange)
                    }
                    fail("the focus layer \(o.layers.focus ?? []) is not the core's \(core); selection \(sel), query window now \(w), focus asked for \(s.focusWindow), visible \(s.visibleRange()), the windowed answer now \(windowed ?? [])")
                }
            } else if o.layers.focus != nil { fail("focus layer while focus mode is off") }
            if !s.syntaxEnabled, !o.layers.pos.isEmpty { fail("part-of-speech layer while syntax is off") }
            // Every character's colour, the whole text.
            let window = o.appliedWindow
            let wanted = OverlayCompositor.compose(o.layers, in: window)
            var k = 0, run = 0
            while k < length {
                var eff = NSRange()
                let actual = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: k, effectiveRange: &eff) as? NSColor
                let end = min(length, max(k + 1, NSMaxRange(eff)))
                var bad = false
                for c in k..<end {
                    var paint: OverlayPaint?
                    if NSLocationInRange(c, window) {
                        while run < wanted.count, NSMaxRange(wanted[run].range) <= c { run += 1 }
                        paint = run < wanted.count && wanted[run].range.location <= c ? wanted[run].paint : nil
                    }
                    if !Self.sameColor(actual, paint.flatMap { o.color(for: $0) }) { fail("character \(c) painted wrong (\(String(describing: paint)), window \(window))"); bad = true; break }
                }
                if bad { break }
                k = end
            }
            // The file the document would write reads back to the same attribution.
            if fileEvery > 0, i % fileEvery == 0, let doc = document, let data = try? doc.data(ofType: "net.daringfireball.markdown") {
                let split = splitAnnotations(fileText: String(decoding: data, as: UTF8.self))
                if let ann = split.annotations {
                    if split.status != .valid { fail("the file written has a block that does not validate: \(split.status)") }
                    let back = Authorship.fromAnnotations(body: split.body, annotations: ann, me: s.authorship.me().name)
                    let names = back.authors().map(\.name), mine = authors.map(\.name)
                    let a1 = back.runs(within: nil).map { "\($0.range.start)-\($0.range.end) \(names[Int($0.authorIndex)])" }
                    let a2 = runs.map { "\($0.range.start)-\($0.range.end) \(mine[Int($0.authorIndex)])" }
                    // (A text without a final newline reads back with one: the blank line before the block.)
                    if split.body != s.text, split.body != s.text + "\n" { fail("the file's body is not the text") }
                    if a1 != a2 { fail("the file reads back to other marks") }
                } else if s.authorship.hasMarks() { fail("marks but no block") }
            }
        }
        // Settled: styling caught up, tagging done, and every answer about the selection applied
        // (checked after at least one run-loop turn, so what the step scheduled has started).
        func settleThen(_ deadline: Date, _ next: @escaping () -> Void) {
            later(0.01) {
                guard let s = self.session else { return next() }
                s.kickDebt()
                if s.isStyled && s.selectionStateSettled && (!s.syntaxEnabled || s.pos.isSettled) { return next() }
                if Date() > deadline {
                    fail("did not settle in time (styled \(s.isStyled), selection answered \(s.selectionStateSettled), tagging done \(s.pos.isSettled))")
                    return next()
                }
                settleThen(deadline, next)
            }
        }
        func step() {
            guard i < steps, let s = session, let tv = textView else {
                var stats: [String: Any] = ["steps": i, "failures": failed]
                for (k, v) in times {
                    let sorted = v.sorted()
                    func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                    stats[k] = ["n": v.count, "p50_ms": pct(0.5), "p99_ms": pct(0.99), "max_ms": sorted.last ?? 0]
                }
                record(["soak": stats], ok: failed == 0)
                done()
                return
            }
            i += 1
            let length = s.storage.length
            func randomPlace() -> Int {
                let ns = s.text as NSString
                let p = Int(rnd() % UInt64(length + 1))
                return p < ns.length ? ns.rangeOfComposedCharacterSequence(at: p).location : p
            }
            let op = Int(rnd() % (toggles ? 20 : 15))
            var name = ""
            let t0 = CFAbsoluteTimeGetCurrent()
            switch op {
            case 0, 1, 2, 3:
                name = "type"
                let w = words[Int(rnd() % UInt64(words.count))]
                opLog.append("type \(w.debugDescription)")
                for c in w { sendKey(String(c)) }
            case 4:
                name = "return"; opLog.append("return"); sendKey("\n")
            case 5:
                name = "backspace"; opLog.append("backspace"); sendKey("\u{7F}", code: 51)
            case 6, 7:
                name = "caret"
                let p = randomPlace()
                let len = rnd() % 3 == 0 ? Int(rnd() % 80) : 0
                let r = (s.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: p, length: min(len, length - p)))
                opLog.append("select \(r)")
                tv.setSelectedRange(len == 0 ? NSRange(location: p, length: 0) : r)
                tv.scrollRangeToVisible(tv.selectedRange())
            case 8:
                name = "pasteAs"
                let pb = scriptPasteboard()
                pb?.clearContents()
                pb?.setString(pastes[Int(rnd() % UInt64(pastes.count))], forType: .string)
                let action = rnd() % 2 == 0 ? #selector(EditorTextView.pasteAsAI(_:)) : #selector(EditorTextView.pasteAsReference(_:))
                opLog.append("\(action) at \(tv.selectedRange())")
                asEvent { _ = NSApp.sendAction(action, to: nil, from: nil) }
            case 9:
                name = "markAs"
                let p = randomPlace()
                let r = (s.text as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: p, length: min(Int(rnd() % 200), length - p)))
                tv.setSelectedRange(r)
                let actions = [#selector(EditorTextView.markAsAI(_:)), #selector(EditorTextView.markAsReference(_:)), #selector(EditorTextView.markAsMe(_:)), #selector(EditorTextView.markAsNoAuthor(_:))]
                let action = actions[Int(rnd() % 4)]
                opLog.append("\(action) \(r)")
                asEvent { _ = NSApp.sendAction(action, to: nil, from: nil) }
            case 10, 11:
                name = "undo"; opLog.append("undo")
                if document?.undoManager?.canUndo == true { document?.undoManager?.undo() }
            case 12:
                name = "redo"; opLog.append("redo")
                if document?.undoManager?.canRedo == true { document?.undoManager?.redo() }
            case 13:
                name = "copyPaste"
                opLog.append("copy+paste \(tv.selectedRange())")
                asEvent { tv.copy(nil) }
                tv.setSelectedRange(NSRange(location: randomPlace(), length: 0))
                asEvent { tv.paste(nil) }
            case 14:
                name = "scroll"
                let p = randomPlace()
                opLog.append("scroll to \(p)")
                tv.scrollRangeToVisible(NSRange(location: p, length: 0))
            case 15:
                name = "mode"
                let mode: ViewMode = s.viewMode == .live ? .source : .live
                opLog.append("mode \(mode)")
                s.setViewMode(mode)
            case 16:
                name = "theme"
                let t = [ThemeChoice.light, .dark, .sepia][Int(rnd() % 3)]
                opLog.append("theme \(t)")
                Settings.shared.theme = t
            case 17:
                name = "focus"; opLog.append("focus toggle"); s.setFocusEnabled(!s.focusEnabled)
            case 18:
                name = "syntax"; opLog.append("syntax toggle"); s.setSyntaxEnabled(!s.syntaxEnabled)
            default:
                name = "authorshipDisplay"; opLog.append("display toggle"); s.setAuthorshipDisplay(!s.authorshipDisplay)
            }
            times[name, default: []].append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            settleThen(Date(timeIntervalSinceNow: 30)) {
                verify()
                later(0, step)
            }
        }
        step()
    }

    /// Moves the caret through the text, `count` steps of `stride` characters, and records how
    /// long the main thread was busy per move (the selection change and everything it causes:
    /// the concealment query and its application), as the arrow keys would.
    private func measureCaret(_ m: [String: Any], then done: @escaping () -> Void) {
        let count = m["count"] as? Int ?? 100
        let stride = m["stride"] as? Int ?? 7
        var perMove: [Double] = []
        var i = 0
        var loc = textView?.selectedRange().location ?? 0
        func step() {
            guard i < count, let tv = textView, let s = session else {
                let sorted = perMove.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
                let stats: [String: Any] = [
                    "moves": perMove.count, "p50_ms": pct(0.5), "p99_ms": pct(0.99), "max_ms": (sorted.last ?? 0) * 1000,
                    "mean_ms": perMove.reduce(0, +) / Double(max(1, perMove.count)) * 1000,
                    "live_queries": session?.liveQueries ?? 0, "state_queries": session?.stateQueries ?? 0,
                    "overlay_ops": session?.overlay.operations ?? 0, "overlay_chars": session?.overlay.charactersTouched ?? 0,
                ]
                let limit = (m["maxMs"] as? NSNumber)?.doubleValue
                record(["measureCaret": stats], ok: limit.map { (sorted.last ?? 0) * 1000 <= $0 } ?? true)
                done()
                return
            }
            loc = (loc + stride) % max(1, s.storage.length)
            let t0 = CFAbsoluteTimeGetCurrent()
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: max(0, loc - 200), length: min(400, s.storage.length - max(0, loc - 200))))
            perMove.append(CFAbsoluteTimeGetCurrent() - t0)
            i += 1
            later(0.005, step)
        }
        step()
    }

    /// Presses an arrow key (`command`) until the caret stops (or `count` presses) and checks Live
    /// mode's caret rules on every press: the press passed something visible (before or after),
    /// and the caret does not rest inside, or at the start of, hidden text.
    private func caretWalk(_ m: [String: Any], then done: @escaping () -> Void) {
        let command = Selector((m["command"] as? String) ?? "moveRight:")
        let count = m["count"] as? Int ?? 100_000
        var problems: [String] = []
        var presses = 0
        var seen: [Int: Int] = [:]
        func step() {
            guard presses < count, let tv = textView, let s = session else { finishWalk(); return }
            let before = tv.selectedRange().location
            // A place reached twice by the same key means the walk goes round in circles (in
            // right-to-left text Right moves backwards: AppKit's visual movement).
            seen[before, default: 0] += 1
            if seen[before]! > 1 {
                let ns = (s.text as NSString)
                let para = ns.paragraphRange(for: NSRange(location: min(before, max(0, ns.length - 1)), length: 0))
                record(["caretWalk": "\(command)", "cycle at": before, "paragraph": ns.substring(with: para)], ok: true)
                finishWalk()
                return
            }
            let liveBefore = s.layoutManager.live
            // (No undo group: an empty one still counts as a change to the document.)
            tv.doCommand(by: command)
            _ = s.waitUntilStyled(timeout: 5)
            let after = tv.selectedRange().location
            presses += 1
            if after == before { finishWalk(); return }
            let live = s.layoutManager.live
            let passed = min(before, after)..<max(before, after)
            if !passed.contains(where: { !liveBefore.isHidden($0) || !live.isHidden($0) }) { problems.append("\(before)->\(after) passed only hidden text") }
            if let h = RangeList.range(containing: live.hidden, after) { problems.append("rests in hidden \(h) at \(after)") }
            later(0, step)
        }
        func finishWalk() {
            record(["caretWalk": "\(command)", "presses": presses, "problems": Array(problems.prefix(20))], ok: problems.isEmpty)
            done()
        }
        step()
    }

    /// Presses an arrow key (`command`, default `moveRight:`) `count` times through the key
    /// bindings and records the main-thread time per press, the concealment it causes included.
    private func measureKeys(_ m: [String: Any], then done: @escaping () -> Void) {
        let count = m["count"] as? Int ?? 200
        let command = Selector((m["command"] as? String) ?? "moveRight:")
        var per: [Double] = []
        var i = 0
        func step() {
            guard i < count, let tv = textView else {
                let sorted = per.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
                let stats: [String: Any] = ["presses": per.count, "p50_ms": pct(0.5), "p99_ms": pct(0.99), "max_ms": (sorted.last ?? 0) * 1000]
                let limit = (m["maxMs"] as? NSNumber)?.doubleValue
                record(["measureKeys": stats, "command": "\(command)"], ok: limit.map { (sorted.last ?? 0) * 1000 <= $0 } ?? true)
                done()
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            asEvent { tv.doCommand(by: command) }
            tv.displayIfNeeded()
            per.append(CFAbsoluteTimeGetCurrent() - t0)
            i += 1
            later(0.005, step)
        }
        step()
    }

    /// Jumps `count` times to places spread over the document (as dragging the scroller does) and
    /// records how long laying out and drawing the screenful takes, the Live-mode query for the
    /// newly visible text included: a proxy for scrolling smoothness.
    private func measureJump(_ m: [String: Any], then done: @escaping () -> Void) {
        let count = m["count"] as? Int ?? 20
        var per: [Double] = []
        var i = 0
        func step() {
            guard i < count, let tv = textView, let s = session, let clip = tv.enclosingScrollView?.contentView else {
                let sorted = per.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
                let stats: [String: Any] = ["jumps": per.count, "p50_ms": pct(0.5), "p99_ms": pct(0.99), "max_ms": (sorted.last ?? 0) * 1000,
                                            "live_queries": session?.liveQueries ?? 0]
                let limit = (m["maxMs"] as? NSNumber)?.doubleValue
                record(["measureJump": stats], ok: limit.map { (sorted.last ?? 0) * 1000 <= $0 } ?? true)
                done()
                return
            }
            // Golden-ratio steps cover the document evenly without repeating.
            let fraction = (Double(i) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            let y = (tv.bounds.height - clip.bounds.height) * CGFloat(fraction)
            let t0 = CFAbsoluteTimeGetCurrent()
            clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
            // Live mode asks about newly visible text on the main queue, before the run loop
            // draws: that turn is part of the jump.
            DispatchQueue.main.async {
                tv.displayIfNeeded()
                per.append(CFAbsoluteTimeGetCurrent() - t0)
                _ = s
                i += 1
                later(0.05, step)
            }
        }
        step()
    }

    /// Types into the document and records how long the preview takes to show it: from the last
    /// keystroke to the page holding the text (the debounce included), and what the core and the
    /// page took. Also the main-thread cost per keystroke, to compare with and without the preview.
    private func measurePreview(_ m: [String: Any], then done: @escaping () -> Void) {
        let count = m["count"] as? Int ?? 40
        let interval = (m["interval"] as? NSNumber)?.doubleValue ?? 0.06
        let rounds = m["rounds"] as? Int ?? 3
        // Fails the step when handing an update to the page held the main thread longer than this.
        let maxMain = (m["maxMainThreadMs"] as? NSNumber)?.doubleValue ?? .infinity
        guard let p = controller?.previewController else { record(["measurePreview": "no preview"], ok: false); done(); return }
        var latencies: [Double] = [], cores: [Double] = [], pages: [Double] = [], calls: [Double] = [], gaps: [Double] = []
        var round = 0
        func nextRound() {
            guard round < rounds else {
                func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
                record(["measurePreview": ["rounds": rounds, "latency_ms_median": latencies.isEmpty ? 0 : med(latencies), "latency_ms_max": latencies.max() ?? 0,
                                           "core_render_ms_median": cores.isEmpty ? 0 : med(cores), "page_update_ms_median": pages.isEmpty ? 0 : med(pages),
                                           "page_update_main_thread_ms_max": calls.max() ?? 0,
                                           "longest_main_thread_gap_while_updating_ms": gaps.max() ?? 0,
                                           "renders": p.renders, "applied": p.applied, "superseded": p.superseded, "patches": p.patchesSent]],
                       ok: !latencies.isEmpty && (calls.max() ?? 0) <= maxMain)
                done()
                return
            }
            round += 1
            let applied0 = p.applied
            var i = 0
            let alphabet = Array("the quick brown fox jumps over the lazy dog ")
            func typeOne() {
                if i < count {
                    sendKey(String(alphabet[i % alphabet.count]))
                    i += 1
                    later(interval, typeOne)
                    return
                }
                let last = CFAbsoluteTimeGetCurrent()
                // The main thread's longest stall while the preview catches up (a 1 ms heartbeat).
                var beat = CFAbsoluteTimeGetCurrent(), longest = 0.0
                let heartbeat = Timer(timeInterval: 0.001, repeats: true) { _ in
                    let now = CFAbsoluteTimeGetCurrent()
                    longest = max(longest, now - beat)
                    beat = now
                }
                RunLoop.main.add(heartbeat, forMode: .common)
                func poll() {
                    if p.isSettled && p.applied > applied0 {
                        heartbeat.invalidate()
                        latencies.append((CFAbsoluteTimeGetCurrent() - last) * 1000)
                        cores.append(p.lastRenderTime * 1000)
                        pages.append(p.lastApplyTime * 1000)
                        calls.append(p.lastApplyMainThreadTime * 1000)
                        gaps.append(longest * 1000)
                        later(0.1, nextRound)
                    } else if CFAbsoluteTimeGetCurrent() - last > 30 {
                        heartbeat.invalidate()
                        record(["measurePreview": "timed out"], ok: false)
                        done()
                    } else {
                        later(0.01, poll)
                    }
                }
                poll()
            }
            typeOne()
        }
        nextRound()
    }

    /// File > Export > PDF without the save panel: into the output directory, then asserted on with `pdf`.
    private func exportPDF(_ name: String, then done: @escaping () -> Void) {
        guard let doc = document else { record(["exportPDF": "no document"], ok: false); done(); return }
        let url = outDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let t0 = CFAbsoluteTimeGetCurrent()
        var gaps: [Double] = []
        var last = CFAbsoluteTimeGetCurrent()
        let heartbeat = Timer(timeInterval: 0.001, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            gaps.append(now - last)
            last = now
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        doc.exportPDF(to: url) { error in
            heartbeat.invalidate()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            self.record(["exportPDF": name, "ms": ms, "bytes": bytes, "pages": PDFInspector.pageCount(url),
                         "longest_main_thread_gap_ms": (gaps.max() ?? 0) * 1000, "error": error.map { "\($0)" } ?? ""], ok: error == nil && bytes > 0)
            done()
        }
    }

    // MARK: windows

    private func snapshot(_ name: String, which: String?, bitmap: Bool = false, then done: @escaping () -> Void) {
        let w: NSWindow? = which == "settings" ? SettingsWindowController.shared.window : (which == "sheet" ? window?.attachedSheet : window)
        guard let w, let content = w.contentView else {
            record(["snapshot": name, "error": "no window"], ok: false)
            done()
            return
        }
        w.displayIfNeeded()
        // The page is web content: the view cache cannot draw it, so it is asked for a picture of
        // itself, which is composited with the rest.
        if w === window, let c = controller, !c.previewPane.isHidden, c.previewController.isVisible {
            let web = c.previewController.webView
            web.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
                if let error { self.record(["snapshot": name, "web view": "\(error)"], ok: false) }
                self.composeSnapshot(name, window: w, content: content, bitmap: bitmap, web: image)
                done()
            }
            return
        }
        composeSnapshot(name, window: w, content: content, bitmap: bitmap, web: nil)
        done()
    }

    private func composeSnapshot(_ name: String, window w: NSWindow, content: NSView, bitmap: Bool, web: NSImage?) {
        let frameView = content.superview ?? content
        let bounds = frameView.bounds
        let out = NSImage(size: bounds.size)
        out.lockFocus()
        w.backgroundColor.setFill()
        bounds.fill()
        // `cacheDisplay` of the whole frame paints an opaque background and misses a clip view's
        // layer-backed contents, so the picture is put together the way the window server would:
        // the text view (as vector PDF, exactly what it draws), then each overlay on top.
        func draw(_ v: NSView) {
            guard !v.isHidden, v.alphaValue > 0.01, v.bounds.width > 0, v.bounds.height > 0,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            NSGraphicsContext.current?.saveGraphicsState()
            rep.draw(in: v.convert(v.bounds, to: frameView), from: .zero, operation: .sourceOver, fraction: v.alphaValue,
                     respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        if w === window, let c = controller, let tv = textView, let clip = tv.enclosingScrollView?.contentView {
            if c.scrollView.isHidden {
                // Preview only: the editor is not drawn.
            } else if bitmap, let rep = tv.bitmapImageRepForCachingDisplay(in: tv.visibleRect) {
                // As drawn on screen, selection and insertion point included (PDF leaves them out).
                tv.cacheDisplay(in: tv.visibleRect, to: rep)
                rep.draw(in: clip.convert(clip.bounds, to: frameView), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            } else if let pdf = NSImage(data: tv.dataWithPDF(inside: tv.visibleRect)) {
                pdf.draw(in: clip.convert(clip.bounds, to: frameView))
            }
            if let web, !c.previewPane.isHidden {
                web.draw(in: c.previewController.webView.convert(c.previewController.webView.bounds, to: frameView))
            }
            for v in c.overlayViews { draw(v) }
            // Title bar: its controls one by one (the bar itself is transparent).
            for v in c.titlebarControls { draw(v) }
        } else {
            for v in content.subviews { draw(v) }
            draw(content)
        }
        out.unlockFocus()
        let url = outDir.appendingPathComponent("\(name).png")
        let png = out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
        let ok = (try? png?.write(to: url)) != nil
        record(["snapshot": url.lastPathComponent, "windowNumber": w.windowNumber, "size": "\(Int(w.frame.width))x\(Int(w.frame.height))"], ok: ok)
    }

    private func close(then done: @escaping () -> Void) {
        guard let doc = document else { done(); return }
        for o: AnyObject in [doc, doc.session, doc.session.coordinator] { seenObjects.add(o) }
        if let tv = textView { seenObjects.add(tv) }
        if let w = window { seenObjects.add(w) }
        weak var s = doc.session
        weak var c = doc.session.coordinator
        weak var tv = textView
        weak var wc = controller
        weak var win = window
        weak var d = doc
        document = nil
        doc.updateChangeCount(.changeCleared)
        doc.close()
        // Let autorelease pools and queued blocks drain.
        // Poll: AppKit itself lets go of a closed text view a little later (the input context and
        // the spell checker hold on to the last first responder for a moment).
        let started = Date()
        func poll() {
            let ours = d == nil && wc == nil && s == nil && c == nil
            let all = ours && win == nil && tv == nil
            if !all && Date().timeIntervalSince(started) < 10 { later(0.25, poll); return }
            let secs = String(format: "%.2f", Date().timeIntervalSince(started))
            self.check("document deallocated", d == nil)
            self.check("window controller deallocated", wc == nil)
            self.check("session deallocated", s == nil)
            self.check("coordinator (and its queue) deallocated", c == nil)
            // AppKit keeps a closed window (and so its text view) for a while, even a plain
            // NSWindow (see `controlLeakProbe`); reported, not judged.
            self.record(["closed window freed": win == nil, "closed text view freed": tv == nil, "after": secs], ok: true)
            self.document = NSDocumentController.shared.documents.last as? MarkdownDocument
            done()
        }
        later(0.25, poll)
    }

    // MARK: assertions

    private static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.003 && abs(x.greenComponent - y.greenComponent) < 0.003
            && abs(x.blueComponent - y.blueComponent) < 0.003 && abs(x.alphaComponent - y.alphaComponent) < 0.003
    }

    private func assertions(_ a: [String: Any]) {
        let text = session?.text ?? ""
        if let v = a["textEquals"] as? String { check("textEquals", text == v, text) }
        if let v = a["textContains"] as? String { check("textContains \(v)", text.contains(v), text) }
        if let v = a["textLacks"] as? String { check("textLacks \(v)", !text.contains(v), text) }
        if let v = a["selection"] as? [Int], let tv = textView {
            let r = tv.selectedRange()
            check("selection \(v)", r.location == v[0] && r.length == v[1], "\(r)")
        }
        if let v = a["selectedText"] as? String, let tv = textView {
            let got = (text as NSString).substring(with: tv.selectedRange())
            check("selectedText \(v)", got == v, got)
        }
        if let v = a["toolbarLit"] as? [String], let c = controller {
            let lit = c.toolbar.litButtonLabels
            check("toolbarLit \(v)", Set(lit) == Set(v), "\(lit)")
        }
        if let v = a["headingTitle"] as? String, let c = controller {
            check("headingTitle \(v)", c.toolbar.headingTitle == v, c.toolbar.headingTitle ?? "nil")
        }
        if let v = a["chromeVisible"] as? Bool, let c = controller {
            check("chromeVisible \(v)", c.chromeVisible == v, "toolbar alpha \(c.toolbar.alphaValue)")
        }
        if a["toolbarIgnoresClicksWhenHidden"] != nil, let c = controller {
            let bar = c.toolbar
            let hidden = bar.alphaValue < 0.5
            let p = NSPoint(x: bar.bounds.midX, y: bar.bounds.midY)
            let hit = bar.hitTest(bar.convert(p, to: bar.superview))
            check("hidden toolbar is not clickable", !hidden || hit == nil, "alpha \(bar.alphaValue) hit \(String(describing: hit))")
            let titleButtonsHidden = c.titlebarButtonsIgnoreClicksWhenHidden
            check("hidden title bar buttons are not clickable", titleButtonsHidden, "")
        }
        if a["caretVisible"] != nil, let tv = textView, let w = window, let c = controller {
            // The caret line is on screen and clear of the title bar and the toolbar.
            var actual = NSRange()
            let r = tv.firstRect(forCharacterRange: NSRange(location: tv.selectedRange().location, length: 0), actualRange: &actual)
            let inWindow = w.convertFromScreen(r)
            let bar = w.frame.height - w.contentLayoutRect.height
            let top = (w.contentView?.bounds.height ?? 0) - bar
            let bottom = c.toolbar.isHidden ? 0 : c.toolbar.frame.maxY
            check("caret visible", inWindow.minY >= bottom && inWindow.maxY <= top, "caret \(inWindow) clear area \(bottom)...\(top)")
        }
        if let v = a["focusLit"] as? [String], let s = session {
            let ns = text as NSString
            let got = (s.overlay.layers.focus ?? []).map { ns.substring(with: RangeMath.clamp($0, toLength: ns.length)) }
            check("focusLit \(v)", got == v, "\(got)")
        }
        if let v = a["focusing"] as? Bool, let s = session { check("focusing \(v)", s.overlay.isFocusing == v) }
        if let v = a["syntaxing"] as? Bool, let s = session { check("syntaxing \(v)", s.pos.isEnabled == v) }
        if let v = a["colors"] as? [String: String], let s = session, let lm = s.textView?.layoutManager {
            // What the text at each needle is painted in: `none` (the stored colour), `dim`, a class.
            s.overlay.apply()
            var bad: [String] = []
            for (needle, want) in v {
                let r = (text as NSString).range(of: needle)
                guard r.location != NSNotFound else { bad.append("\(needle): not found"); continue }
                let paint = s.overlay.appliedPaint(at: r.location)
                let name: String
                switch paint {
                case nil: name = "none"
                case .dim?: name = "dim"
                case .pos(let c)?: name = "\(c)"
                case .authorship(let a)?: name = "author-\(a)"
                }
                let actual = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: r.location, effectiveRange: nil) as? NSColor
                let expected = paint.flatMap { s.overlay.color(for: $0) }
                let agrees = Self.sameColor(actual, expected)
                if name != want || !agrees { bad.append("\(needle): \(name) (layout manager \(agrees ? "agrees" : "differs")), wanted \(want)") }
            }
            check("colors \(v)", bad.isEmpty, "\(bad)")
        }
        if a["overlayConsistent"] != nil, let s = session, let lm = s.textView?.layoutManager {
            // Every character's temporary colour is what the composition of the layers says.
            s.overlay.apply()
            let window = s.overlay.appliedWindow
            let wanted = OverlayCompositor.compose(s.overlay.layers, in: window)
            var wrong = 0
            var first = ""
            var i = window.location
            var runIndex = 0
            while i < NSMaxRange(window) {
                while runIndex < wanted.count, NSMaxRange(wanted[runIndex].range) <= i { runIndex += 1 }
                let paint = runIndex < wanted.count && wanted[runIndex].range.location <= i ? wanted[runIndex].paint : nil
                let actual = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor
                let expected = paint.flatMap { s.overlay.color(for: $0) }
                if !(Self.sameColor(actual, expected)) {
                    wrong += 1
                    if first.isEmpty { first = "first at \(i): \(String(describing: paint))" }
                }
                i += 1
            }
            check("overlay consistent with its layers over \(window)", wrong == 0, "\(wrong) characters differ; \(first)")
        }
        if a["overlayStats"] != nil, let s = session {
            record(["overlay": ["applications": s.overlay.applications, "operations": s.overlay.operations, "characters": s.overlay.charactersTouched,
                                "tagger_invocations": s.pos.taggerInvocations, "cache_hits": s.pos.cacheHits, "cache_misses": s.pos.cacheMisses,
                                "state_queries": s.stateQueries]], ok: true)
        }
        if let v = a["authorship"] as? [String: Any], let s = session {
            // `runs`: [[needle, "me"|"ai"|"reference"|"none"]]: whose every character of the needle is.
            if let runs = v["runs"] as? [[String]] {
                let ns = text as NSString
                let authors = s.authorship.authors()
                var bad: [String] = []
                for pair in runs where pair.count == 2 {
                    let r = ns.range(of: pair[0])
                    guard r.location != NSNotFound else { bad.append("\(pair[0]): not found"); continue }
                    var seen = Set<String>()
                    for i in r.location..<NSMaxRange(r) {
                        if let idx = s.authorship.authorAt(position: UInt32(i)) {
                            seen.insert(idx == 0 ? "me" : (authors[Int(idx)].kind == .ai ? "ai" : "reference"))
                        } else { seen.insert("none") }
                    }
                    if seen != [pair[1]] { bad.append("\(pair[0]): \(seen.sorted()), wanted \(pair[1])") }
                }
                check("authorship runs \(runs)", bad.isEmpty, "\(bad)")
            }
            if let marks = v["marks"] as? Bool { check("authorship has marks \(marks)", s.authorship.hasMarks() == marks) }
            if let on = v["display"] as? Bool { check("authorship display \(on)", s.authorshipDisplay == on) }
            if let count = v["markRuns"] as? Int {
                let n = s.authorship.runs(within: nil).filter { $0.authorIndex != 0 }.count
                check("authorship mark runs \(count)", n == count, "\(n)")
            }
            if let sheet = v["sheet"] as? Bool { check("authorship sheet \(sheet)", (window?.attachedSheet != nil) == sheet) }
            if let pending = v["pendingDecision"] as? Bool { check("authorship decision pending \(pending)", (s.pendingAuthorshipDecision != nil) == pending) }
            if let editable = v["editable"] as? Bool { check("text editable \(editable)", textView?.isEditable == editable) }
        }
        if let v = a["file"] as? [String: Any], let url = document?.fileURL {
            // What is on disk: `contains` / `lacks` / `suffix` (strings).
            let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if let c = v["contains"] as? String { check("file contains \(c.debugDescription)", disk.contains(c), String(disk.suffix(400))) }
            if let c = v["lacks"] as? String { check("file lacks \(c.debugDescription)", !disk.contains(c), String(disk.suffix(400))) }
            if let c = v["suffix"] as? String { check("file ends with \(c.debugDescription)", disk.hasSuffix(c), String(disk.suffix(120))) }
        }
        if let v = a["layout"] as? String { check("layout \(v)", session?.layout.rawValue == v, session?.layout.rawValue ?? "nil") }
        if let v = a["preview"] as? [String: Any], let c = controller {
            let p = c.previewController
            if let want = v["visible"] as? Bool { check("preview visible \(want)", p.isVisible == want && (!c.previewPane.isHidden) == want) }
            if let want = v["editorShown"] as? Bool { check("editor shown \(want)", !c.scrollView.isHidden == want) }
            if let n = v["renders"] as? Int { check("preview renders \(n)", p.renders == n, "\(p.renders)") }
            if v["bodyMatchesCore"] != nil, let s = session {
                // What the page was given is what the core renders for the text now.
                _ = p.waitUntilSettled(timeout: 30)
                let expected = s.coordinator.sync { $0.renderHtml(options: p.renderOptions(standalone: false)) }
                check("preview body equals the core's render", p.lastBodyHTML == expected, "\(p.lastBodyHTML.count) vs \(expected.count) characters")
            }
            for (key, want) in [("contains", true), ("lacks", false)] {
                if let needle = v[key] as? String {
                    let dom = p.evaluateSync("return document.getElementById('md').innerText;") as? String ?? ""
                    check("preview \(key) \(needle.debugDescription)", dom.contains(needle) == want, String(dom.prefix(200)))
                }
            }
            if let needle = v["htmlContains"] as? String {
                let html = p.evaluateSync("return document.getElementById('md').innerHTML;") as? String ?? ""
                check("preview html contains \(needle.debugDescription)", html.contains(needle), String(html.prefix(300)))
            }
            if let want = v["scriptsOff"] as? Bool, want {
                // The page's own JavaScript is off: a script in the document does not run, the app's world still does.
                let ran = p.evaluateSync("return document.body.getAttribute('data-ran') === 'yes';") as? Bool
                check("page javascript is off", ran == false, "\(String(describing: ran))")
            }
            if let want = v["images"] as? [String: Int] {
                let r = p.evaluateSync("const imgs = [...document.images]; return { total: imgs.length, loaded: imgs.filter(i => i.complete && i.naturalWidth > 0).length, broken: imgs.filter(i => i.complete && i.naturalWidth === 0).length };") as? [String: Int] ?? [:]
                check("preview images \(want)", want.allSatisfy { r[$0.key] == $0.value }, "\(r)")
            }
            if let tol = (v["scrollSynced"] as? NSNumber)?.doubleValue {
                _ = p.waitUntilSettled(timeout: 10)
                let e = p.editorReadingPosition() ?? -1
                let page = (p.evaluateSync("return __md.currentLine();") as? NSNumber)?.doubleValue ?? -2
                check("editor and preview at the same line (within \(tol))", abs(e - page) <= tol, "editor \(e), preview \(page), page reported \(p.receivedScrolls.suffix(4)), trace \(p.lastEditorScrollTrace) clip now \(controller?.scrollView.contentView.bounds.minY ?? -1) tvHeight \(textView?.frame.height ?? -1)")
            }
            if let want = v["scrolled"] as? Bool {
                let top = p.scrollTopForTests
                check("preview scrolled \(want)", (top > 1) == want, "scrollTop \(top)")
            }
            if let want = v["styleContains"] as? String {
                let css = p.evaluateSync("return document.head.querySelector('style').textContent;") as? String ?? ""
                check("preview stylesheet contains \(want.debugDescription)", css.contains(want), String(css.prefix(200)))
            }
            if let name = v["computedStyle"] as? [String: String], let property = name["property"], let value = name["is"] {
                let got = p.evaluateSync("return getComputedStyle(document.body)[prop];", arguments: ["prop": property]) as? String ?? ""
                check("preview body \(property) is \(value)", got == value, got)
            }
            if let want = v["linkAction"] as? String { check("preview link action \(want)", "\(String(describing: p.lastLinkAction))".contains(want), "\(String(describing: p.lastLinkAction))") }
        }
        if let v = a["pdf"] as? [String: Any], let name = v["file"] as? String {
            let url = outDir.appendingPathComponent(name)
            let pages = PDFInspector.pageCount(url)
            let text = PDFInspector.text(url)
            if let n = v["minPages"] as? Int { check("pdf has at least \(n) pages", pages >= n, "\(pages)") }
            if let n = v["pages"] as? Int { check("pdf has \(n) pages", pages == n, "\(pages)") }
            for needle in (v["contains"] as? [String]) ?? [] { check("pdf text contains \(needle.debugDescription)", text.contains(needle), String(text.prefix(200))) }
            for needle in (v["lacks"] as? [String]) ?? [] { check("pdf text lacks \(needle.debugDescription)", !text.contains(needle), "") }
            if let n = v["images"] as? Int { let got = PDFInspector.imageCount(url); check("pdf has at least \(n) embedded images", got >= n, "\(got)") }
            if v["light"] != nil {
                // Light print styling whatever the theme: a white page, dark text.
                let corner = PDFInspector.pixel(url, page: 0, x: 4, y: 4)
                let darkest = PDFInspector.darkestLuminance(url, page: 0) ?? 1
                check("pdf page is white", (corner?.r ?? 0) > 0.97 && (corner?.g ?? 0) > 0.97 && (corner?.b ?? 0) > 0.97, "\(String(describing: corner))")
                check("pdf text is dark", darkest < 0.3, "\(darkest)")
            }
            if let m = v["marginsAtLeast"] as? NSNumber {
                // What is visibly drawn on page 0 keeps this many points from every edge. (By ink,
                // not by the text layer: WebKit leaves invisible clipped copies in the margins.)
                if let box = PDFInspector.mediaBox(url, page: 0), let t = PDFInspector.inkBounds(url, page: 0) {
                    let least = min(t.minX - box.minX, box.maxX - t.maxX, t.minY - box.minY, box.maxY - t.maxY)
                    check("pdf ink keeps \(m) points from the edges", least >= CGFloat(m.doubleValue) - 1, "least \(least), ink \(t), page \(box), text layer \(String(describing: PDFInspector.textBounds(url, page: 0)))")
                } else { check("pdf text bounds", false) }
            }
        }
        if let v = a["pasteboard"] as? [String: Any], let pb = scriptPasteboard() {
            let types = Set((pb.types ?? []).map(\.rawValue))
            let html = pb.string(forType: .html) ?? ""
            let plain = pb.string(forType: .string) ?? ""
            if let want = v["types"] as? [String] { check("pasteboard types \(want)", types == Set(want), "\(types.sorted())") }
            for needle in (v["htmlContains"] as? [String]) ?? [] { check("pasteboard html contains \(needle.debugDescription)", html.contains(needle), String(html.prefix(300))) }
            for needle in (v["htmlLacks"] as? [String]) ?? [] { check("pasteboard html lacks \(needle.debugDescription)", !html.contains(needle), String(html.prefix(300))) }
            for needle in (v["plainContains"] as? [String]) ?? [] { check("pasteboard text contains \(needle.debugDescription)", plain.contains(needle), String(plain.prefix(300))) }
            for needle in (v["plainLacks"] as? [String]) ?? [] { check("pasteboard text lacks \(needle.debugDescription)", !plain.contains(needle), String(plain.prefix(300))) }
            if v["rtf"] != nil {
                let rtf = pb.data(forType: .rtf)
                let text = rtf.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string } ?? ""
                check("pasteboard has rich text", (rtf?.count ?? 0) > 0 && !text.isEmpty, "\(rtf?.count ?? 0) bytes")
            }
        }
        if let v = a["viewMode"] as? String { check("viewMode \(v)", session?.viewMode.rawValue == v, session?.viewMode.rawValue ?? "nil") }
        if let v = a["hidden"] as? [String], let s = session {
            _ = s.waitUntilStyled(timeout: 30)
            s.refreshLive()
            let got = s.layoutManager.live.hidden.map { (text as NSString).substring(with: $0) }
            check("hidden \(v)", got == v, "\(got)")
        }
        if let v = a["decorations"] as? [String: Int], let s = session {
            var counts: [String: Int] = [:]
            for d in s.layoutManager.live.decorations {
                let k: String
                switch d.kind {
                case .bullet: k = "bullet"
                case .checkbox: k = "checkbox"
                case .rule: k = "rule"
                case .image: k = "image"
                case .quoteBar: k = "quoteBar"
                }
                counts[k, default: 0] += 1
            }
            check("decorations \(v)", v.allSatisfy { counts[$0.key, default: 0] == $0.value }, "\(counts)")
        }
        if let v = a["collapsedLines"] as? Int, let s = session { check("collapsed lines \(v)", s.layoutManager.live.collapsed.count == v, "\(s.layoutManager.live.collapsed.count)") }
        if let v = a["pasted"] as? Bool { check("pasted \(v)", Self.pasted == v, Self.pasted.map { "\($0)" } ?? "pending") }
        if let v = a["assets"] as? Int {
            // Files in `<document>.assets` beside the current document.
            let url = document?.fileURL
            let dir = url.map { $0.deletingLastPathComponent().appendingPathComponent($0.deletingPathExtension().lastPathComponent + ".assets") }
            let files = dir.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            check("assets \(v)", files.count == v, "\(files)")
        }
        if let v = a["images"] as? [String: Int], let s = session {
            // How many picture decorations are loaded, failed or still loading.
            var counts: [String: Int] = [:]
            for d in s.layoutManager.imageDecorations {
                guard case .image(let destination, _) = d.kind else { continue }
                let e = s.imageController.entry(for: destination, budget: s.imageBudget(), scale: window?.backingScaleFactor ?? 2)
                counts["\(e.phase)", default: 0] += 1
            }
            check("images \(v)", v.allSatisfy { counts[$0.key, default: 0] == $0.value }, "\(counts)")
        }
        if let v = a["linkOpened"] as? String { check("linkOpened \(v)", Self.opened?.absoluteString == v, Self.opened?.absoluteString ?? "nil") }
        if let v = a["inTable"] as? Bool { check("inTable \(v)", session?.formatState.inTable == v) }
        if let v = a["theme"] as? String { check("theme \(v)", session?.appearance.theme.id == v, session?.appearance.theme.id ?? "nil") }
        if a["styled"] != nil, let s = session { check("styled", s.waitUntilStyled(timeout: 30)) }
        if a["coreMatchesText"] != nil, let s = session {
            _ = s.waitUntilStyled(timeout: 30)
            check("core text equals text storage", s.coordinator.coreText() == s.text && s.coordinator.mirrorText() == s.text)
        }
        if let v = a["edited"] as? Bool, let d = document { check("edited \(v)", d.isDocumentEdited == v) }
        if let n = a["closedDocumentsFreed"] as? Int {
            // Closed documents' windows and text views must not pile up (AppKit may keep the
            // last closed window for a while; that is one, not one per document).
            let open = Set(NSDocumentController.shared.documents.flatMap { d -> [ObjectIdentifier] in
                var ids = [ObjectIdentifier(d)]
                if let m = d as? MarkdownDocument { ids += [ObjectIdentifier(m.session), ObjectIdentifier(m.session.coordinator)] }
                for wc in d.windowControllers {
                    if let w = wc.window { ids.append(ObjectIdentifier(w)) }
                    if let e = wc as? EditorWindowController { ids.append(ObjectIdentifier(e.textView)) }
                }
                return ids
            })
            let alive = seenObjects.allObjects.filter { !open.contains(ObjectIdentifier($0)) }
            let names = alive.map { "\(Swift.type(of: $0))" }.sorted()
            let windows = alive.filter { $0 is NSWindow }.count
            let views = alive.filter { $0 is EditorTextView }.count
            let other = alive.count - windows - views
            _ = n
            check("closed documents: no document, session or coordinator left", other == 0, "\(names)")
        }
        if let v = a["fullScreen"] as? Bool, let w = window { check("fullScreen \(v)", w.styleMask.contains(.fullScreen) == v) }
        if let v = a["sheet"] as? Bool, let w = window { check("sheet \(v)", (w.attachedSheet != nil) == v) }
        if let v = a["fontFamily"] as? String, let s = session {
            check("fontFamily \(v)", s.appearance.fonts.body.familyName == v, s.appearance.fonts.body.familyName ?? "nil")
        }
        if let v = a["boldDiffers"] as? Bool, let s = session {
            let f = s.appearance.fonts
            let b = f.variant(of: f.body, bold: true), i = f.variant(of: f.body, italic: true)
            let differs = b.fontName != f.body.fontName && i.fontName != f.body.fontName && b.fontName != i.fontName
            check("bold/italic faces differ from regular: \(v)", differs == v, "\(f.body.fontName) / \(b.fontName) / \(i.fontName)")
        }
        if let v = a["columnCentered"] as? Bool, let tv = textView, let s = session {
            let inset = tv.textContainerInset.width
            let expected = max(EditorAppearance.minimumSideMargin, ((tv.bounds.width - s.appearance.measure) / 2).rounded(.down))
            check("column centered: \(v)", (abs(inset - expected) < 1) == v, "inset \(inset) expected \(expected) width \(tv.bounds.width)")
        }
        if let v = a["spellingSuppressedIn"] as? String, let tv = textView {
            let r = (text as NSString).range(of: v)
            let ok = r.location != NSNotFound && !(tv.session?.allowsSpellChecking(in: r) ?? true)
            check("no spell checking in \(v)", ok)
        }
        if let v = a["spellingAllowedIn"] as? String, let tv = textView {
            let r = (text as NSString).range(of: v)
            let ok = r.location != NSNotFound && (tv.session?.allowsSpellChecking(in: r) ?? false)
            check("spell checking in \(v)", ok)
        }
    }
}

/// Serves the files of one folder over HTTP on the loopback interface, for scripts that need a
/// remote picture without the internet. GET only; just enough HTTP/1.0 for URLSession.
enum LocalHTTPServer {
    private static var listener: NWListener?

    static func start(root: URL, port: UInt16) -> Bool {
        if listener != nil { return true }
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: .tcp, on: p) else { return false }
        l.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let file = root.appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
                var response: Data
                if file.path.hasPrefix(root.standardizedFileURL.path), let body = try? Data(contentsOf: file) {
                    let type = file.pathExtension == "png" ? "image/png" : "application/octet-stream"
                    response = Data("HTTP/1.0 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(body)
                } else {
                    response = Data("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                }
                c.send(content: response, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        l.start(queue: .global())
        listener = l
        return true
    }
}
#endif
