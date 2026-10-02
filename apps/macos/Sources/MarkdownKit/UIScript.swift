#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore

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

final class UIScriptRunner {
    static var isRequested: Bool { scriptPath != nil }

    private static var scriptPath: String? {
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
    static func scriptDefaults() -> UserDefaults? {
        guard isRequested else { return nil }
        let name = "io.github.steeb-k.Markdown.uiscript"
        let d = UserDefaults(suiteName: name)
        d?.removePersistentDomain(forName: name)
        return d
    }

    private static var running: UIScriptRunner?

    /// Every Objective-C exception is logged with its stack, even one that AppKit or a run-loop
    /// callout swallows (a swallowed exception would otherwise just stop the script).
    private static func logExceptions() {
        typealias Preprocessor = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        typealias Setter = @convention(c) (Preprocessor) -> Preprocessor?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else { return }
        let set = unsafeBitCast(sym, to: Setter.self)
        _ = set { raw in
            if let raw, let e = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? NSException {
                let text = "[ui-script] EXCEPTION \(e.name.rawValue): \(e.reason ?? "")\n" + Thread.callStackSymbols.prefix(30).joined(separator: "\n") + "\n"
                FileHandle.standardError.write(Data(text.utf8))
            }
            return raw
        }
    }

    static func startIfRequested() {
        guard let path = scriptPath else { return }
        logExceptions()
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
            open(path, then: done)
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
            asEvent {
                ok = NSApp.sendAction(sel, to: nil, from: sender)
                if !ok, let tv = textView, tv.responds(to: sel) { ok = NSApp.sendAction(sel, to: tv, from: sender) }
            }
            record(["action": action], ok: ok)
            done()
        } else if let command = str("command") {
            asEvent { textView?.doCommand(by: Selector(command)) }
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
            snapshot(name, which: str("window"))
            done()
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
                if s.storage.length > 0 {
                    let a = s.storage.attributes(at: min(40, s.storage.length - 1), effectiveRange: nil)
                    d["attrs40"] = a.map { "\($0.key.rawValue)=\($0.value)" }.sorted()
                }
            }
            record(["dump": d], ok: true)
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

    private func open(_ path: String, then done: @escaping () -> Void) {
        let src = resolve(path)
        let work = outDir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
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

    // MARK: windows

    private func snapshot(_ name: String, which: String?) {
        let w: NSWindow? = which == "settings" ? SettingsWindowController.shared.window : (which == "sheet" ? window?.attachedSheet : window)
        guard let w, let content = w.contentView else {
            record(["snapshot": name, "error": "no window"], ok: false)
            return
        }
        w.displayIfNeeded()
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
            if let pdf = NSImage(data: tv.dataWithPDF(inside: tv.visibleRect)) {
                pdf.draw(in: clip.convert(clip.bounds, to: frameView))
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
#endif
