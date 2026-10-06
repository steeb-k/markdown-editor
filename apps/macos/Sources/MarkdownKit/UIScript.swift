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
///
/// Each step runs in an autorelease pool of its own. AppKit drains the main thread's pool once per
/// event, and a script sends few: what a step autoreleased (a closed document's session, from the
/// reopen before it) otherwise outlived the close by however long the next event took, which made
/// `close`'s check that everything was freed fail at random. A person's next keystroke or pointer
/// move drains it at once.
func later(_ delay: TimeInterval, _ body: @escaping () -> Void) {
    // And it ends the way the handling of an event ends: windows are updated (`NSWindow.update`,
    // which is when a document's edited state reaches its windows).
    let t = Timer(timeInterval: max(0, delay), repeats: false) { _ in
        autoreleasepool { body() }
        MainActor.assumeIsolated {
            NSApp.updateWindows()
            UIScriptRunner.adoptWindows()
        }
    }
    RunLoop.main.add(t, forMode: .common)
}

/// What a person's next event does to the main thread's autorelease pool (AppKit drains it once per
/// event): an application-defined event, which nothing handles.
@MainActor
private func drainEventPool() {
    if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(e, atStart: false)
    }
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

    /// Defaults for `Settings.shared` while a script runs: a private suite, emptied when the script starts and kept
    /// when the app is launched again by a `relaunch` step (`--ui-resume`). `--ui-defaults <name>` names the suite.
    nonisolated static func scriptDefaults() -> UserDefaults? {
        guard isRequested else { return nil }
        let args = ProcessInfo.processInfo.arguments
        let name = args.firstIndex(of: "--ui-defaults").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "io.github.steeb-k.Markdown.uiscript"
        let d = UserDefaults(suiteName: name)
        if !isResuming { d?.removePersistentDomain(forName: name) }
        return d
    }

    /// This launch continues a script that quit and was started again (`relaunch`): the file holds where it was.
    nonisolated static var resumePath: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-resume"), i + 1 < args.count { return args[i + 1] }
        return nil
    }
    nonisolated static var isResuming: Bool { resumePath != nil }

    /// Where the session record is kept while a script runs, when the script uses one (`--ui-record <path>`, and a
    /// `relaunch` or `session` step): never the user's, and not written at all by a script that does not ask.
    nonisolated static var recordURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--ui-record"), i + 1 < args.count, scriptHas(["relaunch", "session"]) else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    /// Whether the script has a step with one of these verbs.
    nonisolated static func scriptHas(_ verbs: Set<String>) -> Bool {
        guard let path = scriptPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return steps.contains { !Set($0.keys).isDisjoint(with: verbs) || (($0["assert"] as? [String: Any]).map { !Set($0.keys).isDisjoint(with: verbs) } ?? false) }
    }

    static var running: UIScriptRunner?
    static let started = Date()
    /// The first `memory` step's footprint, in MB.
    private var memoryBaseline: Double?

    /// The process's physical footprint in MB (task_vm_info), as Activity Monitor's Memory column.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    private static var activity: NSObjectProtocol?

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
    static var opened: URL?
    /// Whether the last `pasteImage` inserted a picture (nil while it waits, e.g. on the save panel).
    private static var pasted: Bool?

    static func startIfRequested() {
        guard let path = scriptPath else { return }
        logExceptions()
        // A script can run for minutes with no one at the machine: without this, macOS treats the
        // app as idle (App Nap, a sleeping display) and throttles its CPU several times over, which
        // shows up as "the app slows down late in a long session" (see `measureDrift`).
        if ProcessInfo.processInfo.environment["UI_SCRIPT_ALLOW_NAP"] == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled, .automaticTerminationDisabled, .suddenTerminationDisabled],
                reason: "UI script")
        }
        LinkOpener.opened = { url in UIScriptRunner.opened = url; return true }
        let runner = UIScriptRunner(script: URL(fileURLWithPath: path))
        // The history of the script's documents goes in a folder of its own beside the output (never the user's);
        // a script started again by `relaunch` goes on with the one it had.
        let history = runner.outDir.appendingPathComponent("history", isDirectory: true)
        if !isResuming { try? FileManager.default.removeItem(at: history) }
        HistoryService.current = HistoryService(directory: history)
        running = runner
        runner.resume()
        QuitConfirmation.run = { alert in runner.answerQuit(alert) }
        later(0.3) { runner.waitForRestoration { runner.run() } }
    }

    // MARK: state

    private let scriptURL: URL
    let outDir: URL
    var steps: [[String: Any]] = []
    var index = 0
    var log: [[String: Any]] = []
    var failures = 0
    var document: MarkdownDocument?
    private var weakProbes: [(String, () -> AnyObject?)] = []
    /// The last Trash move a notes step made: whether the file is in the Trash, and whether the original is still there.
    var lastTrashed: (landed: Bool, original: Bool, path: String)?
    /// Window frames the script has noted (`remember` stores one, `windows.frameKept` compares it).
    var rememberedFrames: [String: NSRect] = [:]
    /// What the last `history` Copy put on its pasteboard.
    var copied: String?
    /// The state the script has noted for after a `relaunch` (`session` `snapshot`): records, as JSON.
    var sessionMemory: [String: String] = [:]
    /// The time the script spent before the app was started again.
    var priorElapsed: TimeInterval = 0
    /// How the next `quit` question is answered, and what it was asked so far.
    var quitAnswer = "quit"
    var quitSuppress = false
    var quitDialogs: [[String: Any]] = []
    /// A `quit` step that expects the question (or not) to be asked: told when the app ends without it having been.
    var expectQuitDialog: Bool?
    var relaunching = false
    var quitDialogsBefore = 0

    private init(script: URL) {
        scriptURL = script
        outDir = UIScriptRunner.outPath.map { URL(fileURLWithPath: $0) }
            ?? script.deletingLastPathComponent().appendingPathComponent("out")
    }

    var controller: EditorWindowController? { document?.windowControllers.first as? EditorWindowController }
    var window: NSWindow? { controller?.window }
    var textView: EditorTextView? { controller?.textView }
    var session: EditorSession? { document?.session }

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
        next()
    }

    /// The steps that need the app active: real mouse events (a click on a window of an inactive app only brings it
    /// forward) and full screen. A script without any never takes activation from the person at the machine.
    nonisolated static let stepsNeedingActivation: Set<String> = ["click", "drag", "slowDrag", "contextMenu", "dividerDrag", "liveResize",
                                                      "doubleClickTitlebar", "fullscreen", "codeBadge"]

    /// Whether the script has such a step. Read at launch: since macOS 14 an app may take activation when it has just
    /// been launched, and not later from the background (`activate` is then refused, and `makeKey` waits in vain), so
    /// a script that needs it takes it at launch, and one that does not leaves the person's app in front.
    nonisolated static var scriptNeedsActivation: Bool {
        guard let path = scriptPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return steps.contains { !Set($0.keys).isDisjoint(with: stepsNeedingActivation) }
    }

    // MARK: windows a person cannot click into

    /// Windows already moved to the corner (each is moved once, when first seen).
    private static let placed = NSHashTable<NSWindow>.weakObjects()

    /// Under a script every window of the app ignores the real mouse (`ignoresMouseEvents`): a person's
    /// click in a window the script was driving mixed with the script's own events (a scripted click and
    /// theirs became a double-click that zoomed the window; a drag step looked like stuck highlighting).
    /// The steps' own mouse events still arrive: they are posted to the app's queue or sent to the window
    /// (`NSApp.postEvent`, `NSWindow.sendEvent`) and never pass the window server's hit-testing, which is
    /// the only thing the flag changes; `clicks.json`, `windows.json`, `titlebar.json`, `focus-resize.json`
    /// and `code.json` pass with it on. Document and Settings windows also open at the top-left corner of
    /// the screen, so a harness window is recognisable. `requested` is for tests.
    static func adopt(_ w: NSWindow, requested: Bool = UIScriptRunner.isRequested) {
        guard requested else { return }
        // Menus, the menu bar, tooltips and the like keep their own handling.
        guard w.level.rawValue < NSWindow.Level.mainMenu.rawValue else { return }
        if !w.ignoresMouseEvents { w.ignoresMouseEvents = true }
        guard !placed.contains(w), w.sheetParent == nil, !w.styleMask.contains(.fullScreen),
              w.windowController is EditorWindowController || w.windowController is SettingsWindowController,
              let screen = w.screen ?? NSScreen.main else { return }
        placed.add(w)
        w.setFrameTopLeftPoint(harnessTopLeft(screen.visibleFrame))
    }

    /// Where a harness window's top-left corner goes: the corner of the screen's visible area.
    static func harnessTopLeft(_ visible: NSRect) -> NSPoint { NSPoint(x: visible.minX, y: visible.maxY) }

    /// `adopt` for every window the app has (after every step, for windows AppKit made: sheets, alerts).
    static func adoptWindows() {
        guard isRequested else { return }
        for w in NSApp.windows { adopt(w) }
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

    func record(_ entry: [String: Any], ok: Bool) {
        var e = entry
        e["step"] = index
        e["ok"] = ok
        // Seconds since the script started, to the millisecond.
        e["t"] = ((Date().timeIntervalSince(Self.started) + priorElapsed) * 1000).rounded() / 1000
        if !ok { failures += 1 }
        log.append(e)
        let line = (try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(e)"
        FileHandle.standardError.write(Data(("[ui-script] " + line + "\n").utf8))
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        record(["assert": name, "detail": detail], ok: ok)
    }

    func finish() {
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

        if let n = step["notes"] as? [String: Any] {
            notesStep(n, then: done)
        } else if let o = step["outline"] as? [String: Any] {
            outlineStep(o, then: done)
        } else if let h = step["history"] as? [String: Any] {
            historyStep(h, then: done)
        } else if let c = step["column"] as? [String: Any] {
            columnStep(c, then: done)
        } else if let a = step["autosave"] as? [String: Any] {
            autosaveStep(a, then: done)
        } else if step["relaunch"] != nil {
            relaunchStep(step["relaunch"] as? [String: Any] ?? [:], then: done)
        } else if let q = step["quit"] as? [String: Any] {
            quitStep(q, then: done)
        } else if let s = step["session"] as? [String: Any] {
            sessionStep(s, then: done)
        } else if let p = step["palette"] {
            paletteStep(p, then: done)
        } else if let path = str("open") {
            open(path, folder: step["folder"] as? Bool ?? false, then: done)
        } else if let m = step["makeFile"] as? [String: Any], let name = m["name"] as? String {
            // A file made here and opened: `prefix` + `text` x `repeat` + `suffix` (UTF-8), or
            // `binary` bytes of noise; `bom`, `lineEndings: "mixed"` (LF, CRLF and CR in turn),
            // `readOnly`. For inputs too big or too odd to keep in the repository.
            let dir = outDir.appendingPathComponent("made", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            var data = Data()
            if let n = m["binary"] as? Int {
                var x: UInt64 = 0x9E37_79B9_7F4A_7C15
                data.reserveCapacity(n)
                for _ in 0..<n { x ^= x << 13; x ^= x >> 7; x ^= x << 17; data.append(UInt8(truncatingIfNeeded: x)) }
            } else {
                var text = (m["prefix"] as? String ?? "") + String(repeating: m["text"] as? String ?? "", count: m["repeat"] as? Int ?? 1) + (m["suffix"] as? String ?? "")
                if m["lineEndings"] as? String == "mixed" {
                    var i = 0
                    text = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).reduce(into: "") { out, line in
                        if i > 0 { out += ["\n", "\r\n", "\r"][i % 3] }
                        out += line
                        i += 1
                    }
                }
                if m["bom"] as? Bool == true { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
                data.append(Data(text.utf8))
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            let ok = FileManager.default.createFile(atPath: url.path, contents: data)
            if m["readOnly"] as? Bool == true { try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path) }
            record(["makeFile": name, "bytes": data.count], ok: ok)
            if m["open"] as? Bool == false {
                done()
            } else if m["expectOpen"] as? Bool == false {
                // A file the app must refuse, with an error rather than a crash or a window of garbage.
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                    self.record(["open": name, "refused": error.map { "\($0.localizedDescription)" } ?? "opened"], ok: doc == nil && error != nil)
                    if let doc { doc.close() }
                    done()
                }
            } else {
                open(url.path, then: done)
            }
        } else if let m = step["modifyOnDisk"] as? [String: Any] {
            // Another program changes the open document's file (its text, without going through the app).
            guard let url = document?.fileURL else { record(["modifyOnDisk": "no file"], ok: false); done(); return }
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if let s = m["append"] as? String { text += s }
            if let s = m["replace"] as? String { text = s }
            var ok = false
            if m["coordinated"] as? Bool == true {
                // As a well-behaved editor writes (TextEdit, Xcode): through a file coordinator, which
                // tells the document (a file presenter) at once.
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { u in
                    ok = (try? Data(text.utf8).write(to: u)) != nil
                }
            } else {
                ok = (try? Data(text.utf8).write(to: url)) != nil
            }
            record(["modifyOnDisk": url.lastPathComponent, "bytes": text.utf8.count], ok: ok)
            done()
        } else if let mode = str("layout") {
            // Through the View menu's action, as the title bar's switch used to be (and a person now does).
            let selector: Selector = mode == "split" ? #selector(EditorWindowController.showSplitLayout(_:))
                : mode == "preview" ? #selector(EditorWindowController.showPreviewLayout(_:)) : #selector(EditorWindowController.showEditorLayout(_:))
            menuAction(selector)
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
            // `expect`: the result, written as a string, must equal it.
            let shown = r.map { "\($0)" } ?? "nil"
            let ok = (step["expect"] as? String).map { shown == $0 } ?? true
            record(["evalPreview": "\(String(describing: r))"], ok: ok)
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
        } else if let f = step["focus"] as? [String: Any] {
            if let scope = f["scope"] as? String, let c = FocusScopeChoice(rawValue: scope) { Settings.shared.focusScope = c }
            if let on = f["on"] as? Bool, on != session?.focusEnabled { menuAction(#selector(EditorTextView.toggleFocusMode(_:))) }
            session?.refreshState(synchronous: true)
            record(["focus": f], ok: session != nil)
            done()
        } else if let f = step["syntax"] as? [String: Any] {
            if let classes = f["classes"] as? [String] {
                for c in SyntaxClass.allCases { Settings.shared.setSyntaxClass(c, classes.contains(c.rawValue)) }
            }
            if let on = f["on"] as? Bool, on != session?.syntaxEnabled { menuAction(#selector(EditorTextView.toggleSyntaxHighlight(_:))) }
            record(["syntax": f], ok: session != nil)
            done()
        } else if step["waitSyntax"] != nil {
            let ok = session?.pos.waitUntilSettled(timeout: num("waitSyntax") ?? 30) ?? false
            record(["waitSyntax": ok, "tagged units": session?.pos.taggerInvocations ?? 0], ok: ok)
            done()
        } else if let c = step["codeBadge"] as? [String: Any], c["real"] as? Bool == true {
            codeBadgeRealStep(c, then: done)
        } else if let c = step["codeBadge"] as? [String: Any] {
            codeBadgeStep(c)
            done()
        } else if let n = step["clickCheckbox"] as? Int {
            var ok = false
            if let tv = textView, let p = tv.taskBoxPoint(n) { ok = tv.handleCheckboxClick(at: p) }
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
            record(["cmdClickLink": needle, "opened": Self.opened?.absoluteString ?? ""], ok: ok)
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
            // `out:work/x.png`: a file in the output directory (one `copyFile` put beside the document).
            pb.writeObjects([(path.hasPrefix("out:") ? outDir.appendingPathComponent(String(path.dropFirst(4))) : resolve(path)) as NSURL])
            let ok = textView?.handleDrop(pb, at: textView?.selectedRange().location ?? 0) ?? false
            pb.releaseGlobally()
            record(["dropFile": path], ok: ok)
            done()
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
        } else if step["frontDocument"] != nil {
            // The script's document becomes the one now in front (a document the app opened by itself,
            // such as Help > Markdown Help), with its name in the log.
            let all = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
            if let d = (NSDocumentController.shared.currentDocument as? MarkdownDocument).flatMap({ $0 === document ? nil : $0 }) ?? all.last(where: { $0 !== document }) { document = d }
            record(["frontDocument": document?.displayName ?? "none", "documents": all.count], ok: document != nil)
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
                // The window's controller (the window's delegate, next in the chain when the window
                // is key; the app need not be active while a script runs, and then no window is).
                if !ok, let wc = self.controller, wc.responds(to: sel) { ok = NSApp.sendAction(sel, to: wc, from: sender) }
                if !ok, let w = self.window, w.responds(to: sel) { ok = NSApp.sendAction(sel, to: w, from: sender) }
                // The document's own (Save).
                if !ok, let d = self.document, d.responds(to: sel) { ok = NSApp.sendAction(sel, to: d, from: sender) }
            }
            // An action that edits runs as one undo group, like an event would. One that does not
            // (`"edits": false`: view toggles) must not: a closed empty group marks the document edited.
            if step["edits"] as? Bool == false { send() } else { asEvent(send) }
            record(["action": action], ok: ok)
            done()
        } else if let command = str("command") {
            let run: () -> Void = { self.textView?.doCommand(by: Selector(command)) }
            if step["edits"] as? Bool == false { run() } else { asEvent(run) }
            // Where the caret ended up: the selection.
            var entry: [String: Any] = ["command": command]
            if let tv = textView {
                let sel = tv.selectedRange()
                entry["selection"] = [sel.location, sel.length]
            }
            var ok = textView != nil
            if let want = step["expectSelection"] as? [Int], let got = entry["selection"] as? [Int] { ok = ok && want == got }
            record(entry, ok: ok)
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
        } else if let d = step["doubleClickTitlebar"] as? [String: Any] {
            doubleClickTitlebar(d, then: done)
        } else if let d = step["liveResize"] as? [String: Any] {
            liveResize(d, then: done)
        } else if let c = step["click"] as? [String: Any] {
            clickStep(c, then: done)
        } else if let d = step["drag"] as? [String: Any] {
            dragStep(d, then: done)
        } else if let d = step["slowDrag"] as? [String: Any] {
            slowDragStep(d, then: done)
        } else if let d = step["contextMenu"] as? [String: Any] {
            contextMenuStep(d, then: done)
        } else if let f = num("dividerDrag") {
            dividerDragStep(f, then: done)
        } else if let d = step["scrollWheel"] as? [String: Any] {
            scrollWheel(d)
            later((d["wait"] as? NSNumber)?.doubleValue ?? 0.2, done)
        } else if let o = step["observeScroll"] as? [String: Any] {
            observeScroll(o, then: done)
        } else if step["dumpTitlebar"] != nil {
            var lines: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                lines.append(String(repeating: " ", count: depth) + "\(Swift.type(of: v)) \(NSStringFromRect(v.frame)) hidden=\(v.isHidden) alpha=\(v.alphaValue)" + ((v as? NSTextField).map { " text=\($0.stringValue.debugDescription)" } ?? ""))
                if depth < 6 { for s in v.subviews { walk(s, depth + 1) } }
            }
            if let f = window?.contentView?.superview { for s in f.subviews where !(s === window?.contentView) { walk(s, 0) } }
            lines.append("accessories: " + (window?.titlebarAccessoryViewControllers.map { "\(Swift.type(of: $0)) \(NSStringFromRect($0.view.frame)) hidden=\($0.isHidden)" }.joined(separator: "; ") ?? ""))
            lines.append("tabbingMode: \(String(describing: window?.tabbingMode.rawValue)) tabGroup windows: \(window?.tabGroup?.windows.count ?? 0)")
            record(["dumpTitlebar": lines], ok: true)
            done()
        } else if let name = str("dumpMenu") {
            // A main-menu menu's items as they stand (AppKit may add some of its own).
            let menu = NSApp.mainMenu?.items.first { $0.title == name }?.submenu
            menu?.update()
            let items = menu?.items.map { $0.isSeparatorItem ? "-" : "\($0.title) [\($0.action.map { NSStringFromSelector($0) } ?? "")]" } ?? []
            record(["dumpMenu": name, "items": items], ok: menu != nil)
            done()
        } else if let name = str("remember") {
            remember(name)
            done()
        } else if let a = step["assert"] as? [String: Any] {
            assertions(a)
            done()
        } else if let size = step["resize"] as? [Double], size.count == 2, let w = window {
            var f = w.frame
            f.origin.y += f.height - size[1]
            // No smaller than a person could make it (setFrame itself ignores the window's minimum).
            f.size = NSSize(width: max(size[0], w.minSize.width), height: max(size[1], w.minSize.height))
            w.setFrame(f, display: true)
            record(["resize": size, "size": [w.frame.width, w.frame.height]], ok: true)
            done()
        } else if let on = step["fullscreen"] as? Bool, window != nil, !NSApp.isActive {
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
        } else if let to = step["switchTo"] as? Int {
            let docs = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
            if to < docs.count { document = docs[to]; window?.makeKeyAndOrderFront(nil) }
            record(["switchTo": to], ok: to < docs.count)
            done()
        } else if let where_ = step["scroll"] {
            scroll(where_)
            // Where the editor ended up and the least it may be (the top of the text under the title bar).
            let clip = textView?.enclosingScrollView?.contentView
            let inset = textView?.enclosingScrollView?.contentInsets.top ?? 0
            // What a person could scroll to: the clip view's own constraint (clip.scroll(to:) skips it).
            let constrained = clip.map { $0.constrainBoundsRect(NSRect(x: 0, y: -2000, width: $0.bounds.width, height: $0.bounds.height)).minY } ?? 0
            // And the other end: how far down a person could scroll, against where the text ends.
            let highest = clip.map { $0.constrainBoundsRect(NSRect(x: 0, y: 10_000_000, width: $0.bounds.width, height: $0.bounds.height)).minY } ?? 0
            let docHeight = textView?.frame.height ?? 0
            let clipHeight = clip?.bounds.height ?? 0
            let insetBottom = textView?.enclosingScrollView?.contentInsets.bottom ?? 0
            var entry: [String: Any] = ["scroll": "\(where_)", "clip_min_y": clip?.bounds.minY ?? 0, "lowest_reachable_y": constrained, "content_inset_top": inset,
                                        "highest_reachable_y": highest, "beyond_end": highest + clipHeight - insetBottom - docHeight,
                                        "find_bar_visible": textView?.enclosingScrollView?.isFindBarVisible ?? false]
            var ok = true
            if let limit = (step["notAbove"] as? NSNumber)?.doubleValue { ok = constrained >= limit - 0.5; entry["not_above"] = limit }
            // `notBeyondEnd`: the text's end may not scroll further up than this many points above the visible bottom.
            if let limit = (step["notBeyondEnd"] as? NSNumber)?.doubleValue { ok = ok && highest + clipHeight - insetBottom - docHeight <= limit + 0.5; entry["not_beyond_end"] = limit }
            record(entry, ok: ok)
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
            // "accept": its first button (Insert, OK).
            // (What the sheet's button does edits the text: as one event, in an undo group of its own.)
            if sheet == "accept", let w = window, let s = w.attachedSheet {
                asEvent { w.endSheet(s, returnCode: .alertFirstButtonReturn) }
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
        } else if let name = str("saveAs") {
            // What File > Save does for an untitled document once the save panel has its answer:
            // the document is written to `work/<name>` in the output directory and from then on is that file.
            guard let doc = document else { record(["saveAs": "no document"], ok: false); done(); return }
            let url = outDir.appendingPathComponent("work", isDirectory: true).appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            doc.save(to: url, ofType: "net.daringfireball.markdown", for: .saveAsOperation) { error in
                self.record(["saveAs": name, "error": error.map { "\($0)" } ?? "", "fileURL": doc.fileURL?.lastPathComponent ?? ""],
                            ok: error == nil && doc.fileURL?.lastPathComponent == name)
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
        } else if let m = step["measureDrift"] as? [String: Any] {
            measureDrift(m, then: done)
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
        } else if let label = str("memory") {
            // The process's memory footprint (what Activity Monitor shows as Memory), in MB; the
            // first one is the baseline for `memoryGrowthMB`; also the live objects of interest.
            let mb = Self.footprintMB()
            if memoryBaseline == nil { memoryBaseline = mb }
            var entry: [String: Any] = ["memory": label, "footprint_mb": (mb * 10).rounded() / 10,
                                        "growth_mb": ((mb - (memoryBaseline ?? mb)) * 10).rounded() / 10,
                                        "documents": NSDocumentController.shared.documents.count,
                                        "windows": NSApp.windows.count, "print_renderers": PrintRenderer.live,
                                        "print_hosts_on_screen": PrintRenderer.hostsOnScreen]
            var ok = true
            if let limit = (step["maxGrowthMB"] as? NSNumber)?.doubleValue {
                ok = mb - (memoryBaseline ?? mb) <= limit
                entry["max_growth_mb"] = limit
            }
            if let n = step["maxPrintRenderers"] as? Int { ok = ok && PrintRenderer.live <= n }
            record(entry, ok: ok)
            done()
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
                d["groupsByEvent"] = document?.undoManager?.groupsByEvent ?? false
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

    func resolve(_ path: String) -> URL {
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
        if let v = s["chromeReturnsAfterPause"] as? Bool { st.chromeReturnsAfterPause = v }
        if let v = s["centreFocusedLine"] as? Bool { st.centreFocusedLine = v }
        if let v = s["focusMode"] as? Bool { st.focusMode = v }
        if let v = s["focusScope"] as? String, let m = FocusScopeChoice(rawValue: v) { st.focusScope = m }
        if let v = s["syntaxHighlight"] as? Bool { st.syntaxHighlight = v }
        if let v = s["authorshipDisplay"] as? Bool { st.authorshipDisplay = v }
        if let v = s["authorName"] as? String { st.authorNameSetting = v }
        if let v = s["reopenAtLaunch"] as? Bool { st.reopenAtLaunch = v }
        if let v = s["askBeforeQuitting"] as? Bool { st.askBeforeQuitting = v }
    }

    // MARK: menus and the title bar

    /// Sends an action as the menu would: along the responder chain, then to the window's own
    /// objects (the app need not be active while a script runs, and then no window is key).
    @discardableResult
    func menuAction(_ sel: Selector, tag: Int = 0) -> Bool {
        let sender = NSMenuItem()
        sender.tag = tag
        var ok = NSApp.sendAction(sel, to: nil, from: sender)
        if !ok, let tv = textView, tv.responds(to: sel) { ok = NSApp.sendAction(sel, to: tv, from: sender) }
        if !ok, let wc = controller, wc.responds(to: sel) { ok = NSApp.sendAction(sel, to: wc, from: sender) }
        if !ok, let d = document, d.responds(to: sel) { ok = NSApp.sendAction(sel, to: d, from: sender) }   // the document's own (Save)
        if !ok, let w = window, w.responds(to: sel) { ok = NSApp.sendAction(sel, to: w, from: sender) }
        return ok
    }

    /// A double-click on the title bar, sent to the window as the window server would send it (one
    /// event with a click count of two: a first click alone would start AppKit's window-drag loop,
    /// which waits for a mouse button that never comes). The window must do what System Settings'
    /// "Double-click a window's title bar to" says: zoom, minimize or nothing.
    private func doubleClickTitlebar(_ d: [String: Any], then done: @escaping () -> Void) {
        guard let w = window, let frameView = w.contentView?.superview else {
            record(["doubleClickTitlebar": "no window"], ok: false)
            done()
            return
        }
        let setting = TitlebarDoubleClick.setting()
        let bar = w.frame.height - w.contentLayoutRect.height
        let x = (d["x"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0.5
        let point = NSPoint(x: x <= 1 ? w.frame.width * x : x, y: w.frame.height - bar / 2)
        let hit = frameView.hitTest(point)
        let before = w.frame
        let miniaturized0 = w.isMiniaturized
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: type == .leftMouseDown ? 1 : 0) {
                w.sendEvent(e)
            }
        }
        // Zooming animates: wait for the frame to move (or, for "nothing", for long enough that it would have).
        let deadline = Date(timeIntervalSinceNow: setting == .nothing ? 0.8 : 3)
        func poll() {
            let changed = w.frame != before || w.isMiniaturized != miniaturized0
            if (changed && setting != .nothing) || Date() >= deadline {
                // Let the animation finish before measuring where it ended.
                later(setting == .nothing ? 0 : 0.6) {
                    let after = w.frame
                    var ok: Bool
                    switch setting {
                    case .zoom: ok = after != before && !w.isMiniaturized
                    case .minimize: ok = w.isMiniaturized
                    case .nothing: ok = after == before && !w.isMiniaturized
                    }
                    if let expect = d["expect"] as? String {
                        ok = ok && (expect == "any" || (expect == "zoom" && setting == .zoom) || (expect == "minimize" && setting == .minimize) || (expect == "none" && setting == .nothing))
                    }
                    self.record(["doubleClickTitlebar": "\(setting)", "hit": hit.map { "\(Swift.type(of: $0))" } ?? "nil",
                                 "at": NSStringFromPoint(point), "before": NSStringFromRect(before), "after": NSStringFromRect(after),
                                 "minimized": w.isMiniaturized, "titlebar_height": bar, "minSize": NSStringFromSize(w.minSize)], ok: ok)
                    if w.isMiniaturized { w.deminiaturize(nil); later(0.8, done) } else { done() }
                }
                return
            }
            later(0.05, poll)
        }
        poll()
    }

    /// A live resize as a person makes one: a mouse-down on the window's bottom-right corner starts
    /// AppKit's own resize loop (`inLiveResize` true throughout), and a timer that runs inside that
    /// loop feeds it one drag at a time (queued all at once they would be coalesced into one), then
    /// the mouse-up. Before each drag, once the window has laid itself out and drawn the frame of
    /// the one before, the caret line's distance from the middle is recorded; then at the mouse-up,
    /// and once things have settled, with every move of the editor's clip view after the mouse-up
    /// (a late correction) and the distance from where a keystroke would put it.
    /// `"steps": [[dw, dh], ...]` in points; `"maxOffset"` fails the step above that distance. `"centred": false`
    /// is for a layout that does not centre (Split): the distances are logged but not held to anything, and the
    /// step fails if a slide starts, the room for centring is there, or the editor moves after the mouse-up.
    private func liveResize(_ d: [String: Any], then done: @escaping () -> Void) {
        guard let w = window, let c = controller else { record(["liveResize": "no window"], ok: false); done(); return }
        let steps = ((d["steps"] as? [[Double]]) ?? []).filter { $0.count == 2 }
        let maxOffset = (d["maxOffset"] as? NSNumber)?.doubleValue ?? 0.5
        let centred = d["centred"] as? Bool ?? true
        func offset() -> Double? {
            guard let middle = visibleMiddleInWindow(), let tv = textView else { return nil }
            var y: CGFloat
            if let caret = caretRectInWindow(), caret.height > 0 {
                y = caret.midY
            } else if let mid = c.centring.lineMidY(at: tv.selectedRange().location) {
                // Scrolled out of sight (the text system gives no caret rectangle): the line's middle from the layout.
                y = tv.convert(NSPoint(x: 0, y: mid), to: nil).y
            } else { return nil }
            return (Double(y - middle) * 100).rounded() / 100
        }
        var perFrame: [Double] = []
        var sizes: [String] = []
        var sawLiveResize = false
        var slid = false
        // Screen coordinates: the corner moves with the window as it is dragged.
        var p = NSPoint(x: w.frame.maxX - 3, y: w.frame.minY + 3)
        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: w.convertPoint(fromScreen: at), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        let before = w.frame
        let clip = c.scrollView.contentView
        var next = 0
        let feeder = Timer(timeInterval: 0.04, repeats: true) { t in
            MainActor.assumeIsolated {
                if w.inLiveResize { sawLiveResize = true }
                if next > 0, let o = offset() { perFrame.append(o); sizes.append("\(Int(w.frame.width))x\(Int(w.frame.height))") }
                if c.centring.isSliding { slid = true }
                if next < steps.count {
                    p.x += steps[next][0]; p.y -= steps[next][1]
                    if let e = event(.leftMouseDragged, p) { NSApp.postEvent(e, atStart: false) }
                    next += 1
                } else {
                    if let e = event(.leftMouseUp, p) { NSApp.postEvent(e, atStart: false) }
                    t.invalidate()
                }
            }
        }
        RunLoop.main.add(feeder, forMode: .common)
        RunLoop.main.add(feeder, forMode: .eventTracking)
        // AppKit's resize loop runs inside this call and returns with the mouse-up.
        if let down = event(.leftMouseDown, p) { w.sendEvent(down) }
        feeder.invalidate()
        let atEnd = offset()
        let endOrigin = clip.bounds.minY
        var lateMoves: [Double] = []
        let moved = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            MainActor.assumeIsolated { lateMoves.append((Double(clip.bounds.minY - endOrigin) * 100).rounded() / 100) }
        }
        later(0.8) {
            NotificationCenter.default.removeObserver(moved)
            let settled = offset()
            let target = c.centring.targetOrigin(for: self.textView?.selectedRange() ?? NSRange())
            let fromTarget = target.map { (Double(clip.bounds.minY - $0) * 100).rounded() / 100 }
            let worst = (perFrame + [atEnd, settled].compactMap { $0 }).map(abs).max() ?? .infinity
            var ok = sawLiveResize && w.frame != before && perFrame.count == steps.count && !slid && lateMoves.isEmpty
            ok = ok && (centred ? worst <= maxOffset && abs(fromTarget ?? .infinity) <= 0.5 : (self.controller?.editorScrollView.focusInset ?? 1) == 0)
            self.record(["liveResize": steps.count, "live": sawLiveResize, "before": NSStringFromRect(before), "after": NSStringFromRect(w.frame),
                         "offsets_per_frame": perFrame, "sizes": sizes, "slid_during_resize": slid,
                         "offset_at_end": (atEnd.map { $0 as Any } ?? NSNull()), "offset_settled": (settled.map { $0 as Any } ?? NSNull()),
                         "late_moves": lateMoves, "origin_minus_keystroke_target": (fromTarget.map { $0 as Any } ?? NSNull()),
                         "textView_origin_y": Double(self.textView?.frame.minY ?? 0),
                         "userScrolling": c.centring.userScrolling], ok: ok)
            done()
        }
    }

    /// Performs an action and watches the editor's clip view while it settles: how many frames the
    /// scroll took, how long, whether it only ever moved one way, and its shape (an ease-in,
    /// ease-out slide is slow at a quarter of the time and has done about half the travel at the middle).
    private func observeScroll(_ o: [String: Any], then done: @escaping () -> Void) {
        guard let c = controller else { record(["observeScroll": "no window"], ok: false); done(); return }
        let clip = c.scrollView.contentView
        var samples: [(t: Double, y: CGFloat)] = []
        let t0 = CFAbsoluteTimeGetCurrent()
        let start = clip.bounds.minY
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
            samples.append((CFAbsoluteTimeGetCurrent() - t0, clip.bounds.minY))
        }
        if let action = o["do"] as? String { menuAction(Selector(action)) }
        if let typed = o["type"] as? String { for ch in typed { sendKey(ch == "\n" ? "\r" : String(ch)) } }
        let seconds = (o["seconds"] as? NSNumber)?.doubleValue ?? 0.8
        later(seconds) {
            NotificationCenter.default.removeObserver(token)
            let end = clip.bounds.minY
            let travel = end - start
            let ys = samples.map(\.y)
            let deltas = zip(ys, ys.dropFirst()).map { $1 - $0 }
            let monotonic = deltas.allSatisfy { travel >= 0 ? $0 >= -0.01 : $0 <= 0.01 }
            let duration = (samples.last?.t ?? 0) - (samples.first?.t ?? 0)
            func progress(atFraction f: Double) -> Double {
                guard let first = samples.first?.t, duration > 0, abs(travel) > 1 else { return 0 }
                let at = first + duration * f
                let y = samples.last(where: { $0.t <= at })?.y ?? start
                return Double((y - start) / travel)
            }
            let gaps = zip(samples, samples.dropFirst()).map { $1.t - $0.t }
            var ok = true
            if let n = (o["expectFrames"] as? NSNumber)?.intValue { ok = ok && samples.count >= n }
            if let r = o["expectDuration"] as? [Double], r.count == 2 { ok = ok && duration >= r[0] && duration <= r[1] }
            if let m = (o["maxFrameGapMs"] as? NSNumber)?.doubleValue { ok = ok && (gaps.max() ?? 0) * 1000 <= m }
            if o["monotonic"] as? Bool == true { ok = ok && monotonic }
            self.record(["observeScroll": o["do"] as? String ?? (o["type"] as? String ?? ""), "frames": samples.count, "duration_ms": duration * 1000, "travel": Double(travel),
                         "monotonic": monotonic, "longest_gap_ms": (gaps.max() ?? 0) * 1000, "mean_gap_ms": gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count) * 1000,
                         "largest_step": Double(deltas.map { abs($0) }.max() ?? 0),
                         "progress_at_25pct": progress(atFraction: 0.25), "progress_at_50pct": progress(atFraction: 0.5), "progress_at_75pct": progress(atFraction: 0.75),
                         "active": c.centring.isActive, "userScrolling": c.centring.userScrolling, "slides": c.centring.slides, "jumps": c.centring.jumps], ok: ok)
            done()
        }
    }

    /// A scroll-wheel event (pixel units, as a trackpad or a smooth mouse makes) delivered to the editor's scroll view.
    private func scrollWheel(_ d: [String: Any]) {
        let dy = Int32((d["dy"] as? NSNumber)?.intValue ?? 0)
        guard let c = controller, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else {
            record(["scrollWheel": dy, "error": "no event"], ok: false)
            return
        }
        let before = c.scrollView.contentView.bounds.minY
        c.scrollView.scrollWheel(with: event)
        record(["scrollWheel": dy, "origin_before": before, "origin_after": c.scrollView.contentView.bounds.minY], ok: true)
    }

    /// The caret's rectangle in window coordinates (the insertion point as the text system places it).
    private func caretRectInWindow() -> NSRect? {
        guard let tv = textView, let w = window else { return nil }
        var actual = NSRange()
        let screen = tv.firstRect(forCharacterRange: NSRange(location: tv.selectedRange().location, length: 0), actualRange: &actual)
        return w.convertFromScreen(screen)
    }

    /// The vertical middle of what the reader sees in the editor (between the title bar and the
    /// formatting bar), in window coordinates.
    private func visibleMiddleInWindow() -> CGFloat? {
        guard let c = controller else { return nil }
        let clip = c.scrollView.contentView
        let rect = clip.convert(clip.bounds, to: nil)
        let top = rect.maxY - c.editorScrollView.baseInsetTop, bottom = rect.minY + c.editorScrollView.baseInsetBottom
        return (top + bottom) / 2
    }

    var remembered: [String: [String: CGFloat]] = [:]

    /// The selection highlight as the text view draws it (`cacheDisplay`, what the window shows): on every line fragment
    /// the selection covers (in view), the band AppKit draws over plain text — from where the selection starts on its first
    /// line, edge to edge on the lines it runs through, up to where it ends on its last — is the highlight colour along the
    /// top of the line (above the glyphs), at least 90% of it. Returns the lines that are not, with their share.
    func selectionDrawnCheck(_ tv: EditorTextView) -> (Bool, String) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return (false, "no text view") }
        let sel = tv.selectedRange()
        guard sel.length > 0 else { return (false, "no selection") }
        let visible = tv.visibleRect
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: visible) else { return (false, "no bitmap") }
        tv.cacheDisplay(in: visible, to: rep)
        let scale = CGFloat(rep.pixelsWide) / visible.width
        let want = ((tv.selectedTextAttributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor)
            .usingColorSpace(.sRGB) ?? .white
        func isHighlight(_ c: NSColor?) -> Bool {
            guard let c = c?.usingColorSpace(.sRGB) else { return false }
            // The highlight is light; text over it is not sampled (the top of the line), so the colour must be close.
            return abs(c.redComponent - want.redComponent) < 0.05 && abs(c.greenComponent - want.greenComponent) < 0.05
                && abs(c.blueComponent - want.blueComponent) < 0.05
        }
        let origin = tv.textContainerOrigin
        let glyphs = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        var lines = 0
        var bad: [String] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, frag, _ in
            let chars = lm.characterRange(forGlyphRange: frag, actualGlyphRange: nil)
            let viewLine = line.offsetBy(dx: origin.x, dy: origin.y)
            guard visible.intersects(viewLine) else { return }
            let fromStart = sel.location < chars.location
            let toEnd = NSMaxRange(sel) >= NSMaxRange(chars)
            let sub = NSIntersectionRange(frag, glyphs)
            let box = lm.boundingRect(forGlyphRange: sub, in: tc)
            let lo = fromStart ? line.minX : box.minX
            let hi = toEnd ? line.maxX : box.maxX
            guard hi - lo > 4 else { return }
            lines += 1
            let y = viewLine.minY + 1.5
            var hits = 0, total = 0
            var x = lo + 2
            while x < hi - 2 {
                let px = Int(((x + origin.x) - visible.minX) * scale), py = Int((y - visible.minY) * scale)
                if px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh {
                    total += 1
                    if isHighlight(rep.colorAt(x: px, y: py)) { hits += 1 }
                }
                x += 3
            }
            if total == 0 || Double(hits) / Double(total) < 0.9 {
                let text = (tv.string as NSString).substring(with: chars).prefix(30)
                bad.append("\"\(text)\" \(hits)/\(total)")
            }
        }
        return (bad.isEmpty && lines > 0, "\(lines) lines; not highlighted: \(bad)")
    }

    /// The middle of the line holding `location`, in the window (where a reader sees that text, scrolled or not).
    func lineYInWindow(_ location: Int) -> CGFloat? {
        guard let tv = textView, let c = controller, location <= tv.string.utf16.count,
              let mid = c.centring.lineMidY(at: location) else { return nil }
        return tv.convert(NSPoint(x: 0, y: mid), to: nil).y
    }
    /// The focus range (what is not dimmed) and the count of dimming operations applied, by `remember` name.
    var rememberedFocus: [String: (keep: [NSRange]?, operations: Int)] = [:]

    private func remember(_ name: String) {
        var v: [String: CGFloat] = [:]
        if let r = caretRectInWindow() { v["caretY"] = r.midY }
        if let c = controller { v["origin"] = c.scrollView.contentView.bounds.minY }
        if let s = session { rememberedFocus[name] = (s.overlay.layers.focus, s.overlay.operations) }
        if let tv = textView, let y = lineYInWindow(tv.selectedRange().location) {
            v["anchor"] = CGFloat(tv.selectedRange().location)
            v["anchorY"] = y
        }
        if let w = controller?.columnView?.frame.width { v["columnWidth"] = w }
        if let w = window { v["titlebar"] = w.frame.height - w.contentLayoutRect.height; rememberedFrames[name] = w.frame }
        remembered[name] = v
        record(["remember": name, "values": v.mapValues { Double($0) }], ok: true)
    }

    /// The editor window in front: the one a person would be typing into.
    var frontController: EditorWindowController? {
        NSApp.orderedWindows.first { $0.isVisible && $0.windowController is EditorWindowController }?.windowController as? EditorWindowController
    }

    /// The script's document becomes the one in the front window (after a click in a sidebar replaced the window's, or opened another).
    func followFront() {
        if let d = frontController?.document as? MarkdownDocument { document = d }
        else if let d = NSDocumentController.shared.documents.last as? MarkdownDocument { document = d }
    }

    /// The state a menu item shows for the front window, validated the way the menu does: by the
    /// first responder that answers its action (with no key window, by this window's own objects).
    private func menuItemState(_ path: String) -> (found: Bool, enabled: Bool, state: NSControl.StateValue, title: String) {
        var menu = NSApp.mainMenu
        var item: NSMenuItem?
        for part in path.components(separatedBy: " > ") {
            item = menu?.items.first { $0.title == part }
            menu = item?.submenu
        }
        guard let item, let action = item.action else { return (false, false, .off, "") }
        let target = NSApp.target(forAction: action, to: nil, from: item)
        var validators: [AnyObject] = []
        if let target { validators.append(target as AnyObject) }
        else {
            if let tv = textView { validators.append(tv) }
            if let wc = controller { validators.append(wc) }
            if let w = window { validators.append(w) }   // the window's own actions, with no key window
            if let delegate = NSApp.delegate { validators.append(delegate as AnyObject) }
        }
        for v in validators where v.responds(to: action) {
            if let m = v as? NSMenuItemValidation { return (true, m.validateMenuItem(item), item.state, item.title) }
            if let u = v as? NSUserInterfaceValidations { return (true, u.validateUserInterfaceItem(item), item.state, item.title) }
            return (true, true, item.state, item.title)
        }
        return (true, false, item.state, item.title)
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
    func asEvent(_ body: () -> Void) {
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
        let centre0 = controller?.centring.timeOnMain ?? 0, slides0 = controller?.centring.slides ?? 0
        let jumps0 = controller?.centring.jumps ?? 0, frames0 = controller?.centring.frames ?? 0
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
                    "mean_centre_ms": ((controller?.centring.timeOnMain ?? 0) - centre0) / Double(count) * 1000,
                    "centre_slides": (controller?.centring.slides ?? 0) - slides0, "centre_jumps": (controller?.centring.jumps ?? 0) - jumps0,
                    "centre_frames": (controller?.centring.frames ?? 0) - frames0, "centre_longest_frame_ms": (controller?.centring.longestFrame ?? 0) * 1000,
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
    /// scrolling, themes, focus mode, syntax highlighting and the authorship
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
                let w = s.queryWindow()
                let scope: FocusScope = s.settings.focusScope == .sentence ? .sentence : .paragraph
                let core = s.coordinator.sync { doc in
                    doc.focusRange(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))), scope: scope).map(\.nsRange)
                }
                // Where the layer must match: the query window, but for a selection only the part the
                // focus was last asked about (the units a selection touches are worked out inside the
                // window asked for; text scrolled into view is asked about again before it is within
                // 2,000 characters of being shown, see `visibleRangeChanged`). Focus mode's centring
                // moves the view after the question was asked, so the window now and the window asked
                // for differ more often than they did. What is on screen must always match.
                let region = sel.length > 0 && s.focusWindow.length > 0 ? NSIntersectionRange(w, s.focusWindow) : w
                func clip(_ rs: [NSRange], _ r: NSRange = region) -> [NSRange] { rs.map { NSIntersectionRange($0, r) }.filter { $0.length > 0 } }
                let visible = s.visibleRange()
                if clip(o.layers.focus ?? []) != clip(core) || clip(o.layers.focus ?? [], visible) != clip(core, visible) {
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
                if s.isStyled && s.selectionStateSettled && (!s.syntaxEnabled || s.pos.isSettled) && (self.controller?.centring.isSettled ?? true) { return next() }
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
                name = "caret"
                let p = randomPlace()
                opLog.append("caret \(p)")
                tv.setSelectedRange(NSRange(location: p, length: 0))
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
    /// the state query and its application), as the arrow keys would.
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
                    "state_queries": session?.stateQueries ?? 0,
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

    /// How long a fixed amount of arithmetic takes here and now: tells a slow machine (thermal
    /// throttling, other processes) from a slow app.
    nonisolated static func calibrate() -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        var x: UInt64 = 88172645463325252
        for _ in 0..<20_000_000 { x ^= x << 13; x ^= x >> 7; x ^= x << 17 }
        if x == 1 { print("") }
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// A long session at random: each round jumps the caret to `moves` scattered places, then
    /// types `keys` characters (with a Backspace now and then) at the last one, and records the
    /// main-thread cost per key and per jump together with the size of everything the session
    /// keeps (overlay runs, attribute runs, undo steps). The cost per key in the
    /// first tenth of the rounds is compared with the last tenth: a cost that grows with the
    /// length of the session fails (`factor`, default 2, plus `slackMs`, default 1).
    private func measureDrift(_ m: [String: Any], then done: @escaping () -> Void) {
        let rounds = m["rounds"] as? Int ?? 100
        let keys = m["keys"] as? Int ?? 20
        let moves = m["moves"] as? Int ?? 4
        let factor = (m["factor"] as? NSNumber)?.doubleValue ?? 2
        let slack = (m["slackMs"] as? NSNumber)?.doubleValue ?? 1
        let sampleEvery = max(1, m["sampleEvery"] as? Int ?? max(1, rounds / 10))
        var seed = UInt64(m["seed"] as? Int ?? 7) &+ 0x9E37_79B9_7F4A_7C15
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, n)))
        }
        func attributeRuns(_ s: EditorSession) -> Int {
            var n = 0
            s.storage.enumerateAttributes(in: NSRange(location: 0, length: s.storage.length), options: []) { _, _, _ in n += 1 }
            return n
        }
        guard let s0 = session else { record(["measureDrift": "no session"], ok: false); done(); return }
        let runs0 = attributeRuns(s0)
        var keyMs: [Double] = [], moveMs: [Double] = [], calibration: [Double] = []
        var samples: [[String: Any]] = []
        var typed = 0
        var round = 0
        let alphabet = Array("the quick brown fox jumps over the lazy dog ")
        func finish() {
            guard let s = session else { done(); return }
            let tenth = max(1, rounds / 10)
            func mean(_ a: ArraySlice<Double>) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
            let k0 = mean(keyMs.prefix(tenth)), k1 = mean(keyMs.suffix(tenth))
            let m0 = mean(moveMs.prefix(tenth)), m1 = mean(moveMs.suffix(tenth))
            // Judged against how fast the machine was at the start and at the end (a fixed loop
            // timed every round): a throttled machine is not a slow app.
            let c0 = mean(calibration.prefix(tenth)), c1 = mean(calibration.suffix(tenth))
            let speed = c0 > 0 ? c1 / c0 : 1
            let ok = k1 <= k0 * factor * max(1, speed) + slack && m1 <= m0 * factor * max(1, speed) + slack
            record(["measureDrift": ["rounds": rounds, "keys_typed": typed,
                                     "key_ms_first_tenth": k0, "key_ms_last_tenth": k1,
                                     "move_ms_first_tenth": m0, "move_ms_last_tenth": m1,
                                     "machine_slowdown": speed,
                                     "key_ratio": k0 > 0 ? k1 / k0 : 0, "move_ratio": m0 > 0 ? m1 / m0 : 0,
                                     "attribute_runs_before": runs0, "attribute_runs_after": attributeRuns(s),
                                     "key_ms_by_round": keyMs.map { ($0 * 10).rounded() / 10 },
                                     "samples": samples] as [String: Any]], ok: ok)
            done()
        }
        func oneRound() {
            guard round < rounds, let tv = textView, let s = session else { finish(); return }
            let wait0 = s.coordinator.totalWaitTime, style0 = s.totalStyleTime, state0 = s.timeInStateQueries
            let edit0 = s.overlay.timeFollowingEdits, apply0 = s.overlay.timeApplying
            let phases0 = s.phaseTimes
            let inst0 = s.coordinator.instrumentation, sync0 = s.coordinator.totalSyncTime
            var moveTotal = 0.0
            for _ in 0..<moves {
                let loc = rnd(max(1, s.storage.length - 1))
                let t0 = CFAbsoluteTimeGetCurrent()
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
                tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: max(0, loc - 200), length: min(400, s.storage.length - max(0, loc - 200))))
                moveTotal += CFAbsoluteTimeGetCurrent() - t0
                _ = s.waitUntilStyled(timeout: 5)
            }
            moveMs.append(moveTotal / Double(max(1, moves)) * 1000)
            calibration.append(Self.calibrate())
            var keyTotal = 0.0
            for k in 0..<keys {
                let t0 = CFAbsoluteTimeGetCurrent()
                if k % 11 == 10 { sendKey("\u{7F}", code: 51) } else { sendKey(String(alphabet[(typed + k) % alphabet.count])) }
                keyTotal += CFAbsoluteTimeGetCurrent() - t0
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
            typed += keys
            keyMs.append(keyTotal / Double(max(1, keys)) * 1000)
            _ = s.waitUntilStyled(timeout: 10)
            if round % sampleEvery == 0 || round == rounds - 1 {
                samples.append(["round": round, "key_ms": keyMs.last ?? 0, "move_ms": moveMs.last ?? 0,
                                "wait_ms": (s.coordinator.totalWaitTime - wait0) / Double(keys) * 1000,
                                "style_ms": (s.totalStyleTime - style0) / Double(keys) * 1000,
                                "state_ms": (s.timeInStateQueries - state0) / Double(keys + moves) * 1000,
                                "overlay_edit_ms": (s.overlay.timeFollowingEdits - edit0) / Double(keys) * 1000,
                                "overlay_apply_ms": (s.overlay.timeApplying - apply0) / Double(keys) * 1000,
                                "phases_ms_per_key": s.phaseTimes.mapValues { _ in 0 }.merging(s.phaseTimes) { _, v in v }
                                    .reduce(into: [String: Double]()) { $0[$1.key] = (($1.value - (phases0[$1.key] ?? 0)) / Double(keys) * 10_000).rounded() / 10 },
                                "analysis_ms_per_edit": ((s.coordinator.instrumentation.process - inst0.process) * 1000 / Double(max(1, s.coordinator.instrumentation.edits - inst0.edits))),
                                "fetch_ms_per_edit": ((s.coordinator.instrumentation.fetch - inst0.fetch) * 1000 / Double(max(1, s.coordinator.instrumentation.edits - inst0.edits))),
                                "edits_analysed": s.coordinator.instrumentation.edits - inst0.edits,
                                "main_sync_ms_per_key": (s.coordinator.totalSyncTime - sync0) * 1000 / Double(keys + moves),
                                "calibration_ms": calibration.last ?? 0,
                                "overlay_applied": s.overlay.applied.count,
                                "owed": s.owedStyling.count,
                                "attribute_runs": attributeRuns(s)])
            }
            if let e = m["experiment"] as? [String: Any], e["round"] as? Int == round, let what = e["do"] as? String {
                let whole = NSRange(location: 0, length: s.storage.length)
                switch what {
                case "removeUndo": document?.undoManager?.removeAllActions()
                case "invalidateLayout": s.layoutManager.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
                case "invalidateGlyphs": s.layoutManager.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
                case "removeTemporary": s.layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
                default: break
                }
                samples.append(["experiment": what, "round": round])
            }
            round += 1
            later(0, oneRound)
        }
        oneRound()
    }

    /// Presses an arrow key (`command`, default `moveRight:`) `count` times through the key
    /// bindings and records the main-thread time per press.
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
    /// records how long laying out and drawing the screenful takes: a proxy for scrolling smoothness.
    private func measureJump(_ m: [String: Any], then done: @escaping () -> Void) {
        let count = m["count"] as? Int ?? 20
        var per: [Double] = []
        var i = 0
        func step() {
            guard i < count, let tv = textView, let s = session, let clip = tv.enclosingScrollView?.contentView else {
                let sorted = per.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
                let stats: [String: Any] = ["jumps": per.count, "p50_ms": pct(0.5), "p99_ms": pct(0.99), "max_ms": (sorted.last ?? 0) * 1000]
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
            // What asks about newly visible text on the main queue runs before the run loop
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
            if let sb = c.sidebar?.view { draw(sb) }
            if let column = c.columnView { draw(column) }
            if let bar = c.changeBar { draw(bar) }
            for v in c.overlayViews { draw(v) }
            if let p = c.palette, p.isOpen { draw(p.panel) }
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
        weak let s = doc.session
        weak let c = doc.session.coordinator
        weak let tv = textView
        weak let wc = controller
        weak let win = window
        weak let d = doc
        // Also the preview's web view and preview controller, .
        weak let web = controller?.previewController.webView
        weak let pc = controller?.previewController
        document = nil
        doc.updateChangeCount(.changeCleared)
        doc.close()
        // Let autorelease pools and queued blocks drain.
        // Poll: AppKit itself lets go of a closed text view a little later (the input context and
        // the spell checker hold on to the last first responder for a moment).
        let started = Date()
        func poll() {
            drainEventPool()
            let ours = d == nil && wc == nil && s == nil && c == nil && pc == nil
            let all = ours && win == nil && tv == nil && web == nil
            if !all && Date().timeIntervalSince(started) < 10 { later(0.25, poll); return }
            let secs = String(format: "%.2f", Date().timeIntervalSince(started))
            self.check("document deallocated", d == nil)
            self.check("window controller deallocated", wc == nil)
            self.check("session deallocated", s == nil)
            self.check("coordinator (and its queue) deallocated", c == nil)
            self.check("preview controller deallocated", pc == nil)
            self.record(["closed web view freed": web == nil, "print renderers alive": PrintRenderer.live], ok: true)
            // AppKit keeps a closed window (and so its text view) for a while, even a plain
            // NSWindow (see `controlLeakProbe`); reported, not judged.
            self.record(["closed window freed": win == nil, "closed text view freed": tv == nil, "after": secs], ok: true)
            self.document = NSDocumentController.shared.documents.last as? MarkdownDocument
            // UI_SCRIPT_LEAK_PAUSE=<seconds>: what outlived its document is logged with its address and
            // the script waits, so that `leaks --traceTree=<address> <pid>` can say what holds it.
            if !ours, let pause = ProcessInfo.processInfo.environment["UI_SCRIPT_LEAK_PAUSE"].flatMap(Double.init) {
                var alive: [String: String] = ["pid": "\(getpid())"]
                for (name, o) in [("session", s as AnyObject?), ("coordinator", c), ("document", d), ("controller", wc)] {
                    if let o { alive[name] = "\(Unmanaged.passUnretained(o).toOpaque())" }
                }
                self.record(["leakPause": pause, "alive": alive], ok: true)
                FileHandle.standardError.write("[ui-script] leak pause \(alive)\n".data(using: .utf8)!)
                later(pause, done)
                return
            }
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
        if let s = a["session"] as? [String: Any] { sessionAssertions(s) }
        if let v = (a["textEquals"] as? String).map(expandVars) { check("textEquals", text == v, text) }
        if let v = (a["textContains"] as? String).map(expandVars) { check("textContains \(v)", text.contains(v), text) }
        if let v = (a["textLacks"] as? String).map(expandVars) { check("textLacks \(v)", !text.contains(v), text) }
        if let v = a["fileEqualsMade"] as? String {
            // The document's file, byte for byte, is the file `makeFile` made (opened and saved untouched).
            let made = try? Data(contentsOf: outDir.appendingPathComponent("made").appendingPathComponent(v))
            let disk = document?.fileURL.flatMap { try? Data(contentsOf: $0) }
            check("file equals made/\(v)", made != nil && made == disk, "\(made?.count ?? -1) vs \(disk?.count ?? -1) bytes")
        }
        if let v = a["textLength"] as? Int { check("textLength \(v)", (text as NSString).length == v, "\((text as NSString).length)") }
        if a["harnessWindows"] as? Bool == true {
            // Every visible window of the app ignores the real mouse; the script's window sits at the screen's top-left
            // (`"atCorner": false` skips that, after a step that moves the window).
            let visible = NSApp.windows.filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.mainMenu.rawValue }
            let listening = visible.filter { !$0.ignoresMouseEvents }.map { "\(Swift.type(of: $0)) \($0.title)" }
            var detail = "listening: \(listening)"
            var ok = listening.isEmpty && !visible.isEmpty
            if a["atCorner"] as? Bool != false, let w = window, let screen = w.screen {
                let want = UIScriptRunner.harnessTopLeft(screen.visibleFrame)
                let got = NSPoint(x: w.frame.minX, y: w.frame.maxY)
                detail += " top-left \(NSStringFromPoint(got)) want \(NSStringFromPoint(want))"
                ok = ok && abs(got.x - want.x) < 1 && abs(got.y - want.y) < 1
            }
            check("harnessWindows", ok, detail + " active \(NSApp.isActive)")
        }
        if let v = a["selection"] as? [Int], let tv = textView {
            let r = tv.selectedRange()
            check("selection \(v)", r.location == v[0] && r.length == v[1], "\(r)")
        }
        if let want = a["selectionEmpty"] as? Bool, let tv = textView {
            let r = tv.selectedRange()
            check("selectionEmpty \(want)", (r.length == 0) == want, "\(r)")
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
        if let v = a["focusCentred"] {
            // The caret's line is within `tolerance` points of the middle of what the reader sees.
            let tolerance = (v as? NSNumber)?.doubleValue ?? ((v as? [String: Any])?["tolerance"] as? NSNumber)?.doubleValue ?? 2
            if let caret = caretRectInWindow(), let middle = visibleMiddleInWindow() {
                let d = Double(caret.midY - middle)
                check("focusCentred (within \(tolerance) pt)", abs(d) <= tolerance, "caret line is \(String(format: "%.2f", d)) pt from the middle")
            } else { check("focusCentred", false, "no caret or view") }
        }
        if let want = a["focusInsets"] as? Bool, let c = controller, let w = window {
            let bar = w.frame.height - w.contentLayoutRect.height
            let insets = c.scrollView.contentInsets
            let extra = c.editorScrollView.focusInset
            let ok = want ? (extra > 0 && abs(insets.top - bar - extra) < 0.5 && abs(insets.bottom - c.editorScrollView.baseInsetBottom - extra) < 0.5)
                          : (extra == 0 && abs(insets.top - bar) < 0.5)
            check("focusInsets \(want)", ok, "extra \(extra) top \(insets.top) bottom \(insets.bottom) title bar \(bar)")
        }
        if let want = a["userScrolling"] as? Bool, let c = controller {
            check("userScrolling \(want)", c.centring.userScrolling == want)
        }
        if let want = a["sliding"] as? Bool, let c = controller {
            check("sliding \(want)", c.centring.isSliding == want)
        }
        if let name = a["caretUnmoved"] as? String {
            let tolerance = (a["tolerance"] as? NSNumber)?.doubleValue ?? 1.5
            if let was = remembered[name]?["caretY"], let now = caretRectInWindow()?.midY {
                check("caret line unmoved since \(name)", abs(Double(now - was)) <= tolerance, "moved \(Double(now - was)) pt")
            } else { check("caret line unmoved since \(name)", false, "nothing remembered") }
        }
        if let name = a["originUnchanged"] as? String, let c = controller {
            let was = remembered[name]?["origin"], now = c.scrollView.contentView.bounds.minY
            check("scroll origin unchanged since \(name)", was.map { abs($0 - now) < 0.5 } ?? false, "was \(String(describing: was)) now \(now)")
        }
        if let name = a["originChanged"] as? String, let c = controller {
            let was = remembered[name]?["origin"], now = c.scrollView.contentView.bounds.minY
            check("scroll origin changed since \(name)", was.map { abs($0 - now) >= 1 } ?? false, "was \(String(describing: was)) now \(now)")
        }
        if let name = a["titlebarHeightSameAs"] as? String, let w = window {
            let bar = w.frame.height - w.contentLayoutRect.height
            let was = remembered[name]?["titlebar"]
            check("title bar height unchanged since \(name)", was.map { abs($0 - bar) < 0.5 } ?? false, "was \(String(describing: was)) now \(bar)")
        }
        if a["titlebarClean"] != nil, let c = controller, let w = window {
            // The title bar holds the window buttons and the app's own title, and nothing else: AppKit's title views (the
            // title, its icon, the "Edited" button and the dash) are hidden, no accessory is showing, and the title is
            // drawn, with the window's own name, inside the editor's pane.
            var strays: [String] = []
            func walk(_ v: NSView) {
                // AppKit's own: the window buttons; its title views are checked below.
                let own = c.chromeController.windowButtons.contains(v) || SystemTitle.isSystemTitleView(v) || "\(Swift.type(of: v))".hasPrefix("NSTheme")
                if v is NSControl, !own { strays.append("\(Swift.type(of: v))") }
                for s in v.subviews where !s.isHidden && s.frame.height > 0 { walk(s) }
            }
            for bar in c.titlebarControls where bar !== c.titleView { walk(bar) }
            let accessories = w.titlebarAccessoryViewControllers.filter { !$0.isHidden }
            let systemShowing = SystemTitle.views(in: w).filter { !$0.isHidden }.map { "\(Swift.type(of: $0))" }
            let tv = c.titleView
            let problem = titleProblem(c, w)
            check("title bar has no custom controls", strays.isEmpty && accessories.isEmpty && systemShowing.isEmpty && w.titleVisibility == .hidden && problem == nil,
                  "controls \(strays) accessories \(accessories.map { "\(Swift.type(of: $0.view))" }) system title showing \(systemShowing) title visibility \(w.titleVisibility.rawValue) title view \(tv.name.debugDescription) \(problem ?? "")")
        }
        if let t = a["title"] as? [String: Any], let c = controller, let w = window { titleAssertions(t, c, w) }
        if let t = a["windows"] as? [String: Any], let w = window {
            // The editor windows, front to back: one document each.
            let fronts = NSApp.orderedWindows.filter { $0.isVisible && $0.windowController is EditorWindowController }
            let docs = fronts.compactMap { ($0.windowController as? EditorWindowController)?.markdownDocument }
            if let n = t["count"] as? Int { check("windows \(n)", fronts.count == n, "\(fronts.count)") }
            if let titles = (t["titles"] as? [String])?.map(expandVars) { check("window titles \(titles)", docs.map { $0.displayName ?? "" } == titles, "\(docs.map { $0.displayName ?? "" })") }
            if let n = t["documents"] as? Int { check("documents \(n)", NSDocumentController.shared.documents.count == n, "\(NSDocumentController.shared.documents.count)") }
            if t["tabbingDisallowed"] as? Bool == true {
                let ok = fronts.allSatisfy { $0.tabbingMode == .disallowed && ($0.tabGroup?.windows.count ?? 1) <= 1 } && !NSWindow.allowsAutomaticWindowTabbing
                check("tabbing disallowed", ok, "modes \(fronts.map { $0.tabbingMode.rawValue }) automatic \(NSWindow.allowsAutomaticWindowTabbing)")
            }
            if let v = t["titleShown"] as? Bool, let c = controller {
                let shown = c.titleView.superview != nil && !c.titleView.isHidden && c.titleView.name == w.title && !w.title.isEmpty
                check("title shown \(v)", shown == v, "title view \(c.titleView.name.debugDescription) window title \(w.title.debugDescription)")
            }
            if let v = t["title"] as? String { check("window title \(v)", w.title == v, w.title.debugDescription) }
            // The red button's dot: the window's own flag. The title's "Edited" follows the document's.
            if let v = t["editedDot"] as? Bool { check("edited dot \(v)", w.isDocumentEdited == v, "window \(w.isDocumentEdited) document \(String(describing: document?.isDocumentEdited))") }
            if let v = t["documentEdited"] as? Bool { check("document edited \(v)", document?.isDocumentEdited == v, "\(String(describing: document?.isDocumentEdited))") }
            if let v = t["frameKept"] as? String, let was = rememberedFrames[v] {
                check("window frame as it was at \(v)", abs(was.minX - w.frame.minX) < 1.5 && abs(was.maxY - w.frame.maxY) < 1.5 && abs(was.width - w.frame.width) < 1.5 && abs(was.height - w.frame.height) < 1.5, "\(was) now \(w.frame)")
            }
        }
        if let h = a["history"] as? [String: Any] { historyAssertions(h) }
        if let c = a["column"] as? [String: Any] { columnAssertions(c) }
        if let f = a["documentFile"] as? [String: Any] { fileAssertions(f) }
        if let n = a["notes"] as? [String: Any] { notesAssertions(n) }
        if let o = a["outline"] as? [String: Any] { outlineAssertions(o) }
        if let c = a["code"] as? [String: Any] { codeAssertions(c) }
        if let p = a["palette"] as? [String: Any] { paletteAssertions(p) }
        if let menus = a["menu"] as? [String: Any] {
            for (path, want) in menus.sorted(by: { $0.key < $1.key }) {
                let got = menuItemState(path)
                var ok = got.found
                var detail = "enabled \(got.enabled) state \(got.state == .on ? "on" : "off") title \(got.title)"
                if let w = want as? [String: Any], w["absent"] as? Bool == true {
                    // No such item at all (whatever its action).
                    var menu = NSApp.mainMenu
                    var item: NSMenuItem?
                    for part in path.components(separatedBy: " > ") {
                        item = menu?.items.first { $0.title == part }
                        menu = item?.submenu
                    }
                    check("menu \(path) absent", item == nil, item.map { "found, action \($0.action.map { NSStringFromSelector($0) } ?? "none")" } ?? "")
                    continue
                }
                if let w = want as? [String: Any] {
                    if let st = w["state"] as? String { ok = ok && (got.state == .on) == (st == "on") }
                    if let en = w["enabled"] as? Bool { ok = ok && got.enabled == en }
                    if let t = w["title"] as? String { ok = ok && got.title == t }
                }
                check("menu \(path)", ok, detail)
                detail = ""
            }
        }
        if let n = a["chromeReturnsByPause"] as? Int, let c = controller {
            check("chrome came back by itself \(n) time(s)", c.chromeController.pauseReappearances == n, "\(c.chromeController.pauseReappearances)")
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
        if let name = a["focusUnchanged"] as? String, let s = session {
            // The dimming is where it was: the same focus range, and no temporary attribute changed since.
            let ns = text as NSString
            let lit = { (r: [NSRange]?) in (r ?? []).map { ns.substring(with: RangeMath.clamp($0, toLength: ns.length)).prefix(24) } }
            if let was = rememberedFocus[name] {
                let ops = s.overlay.operations - was.operations
                check("focus unchanged since \(name)", s.overlay.layers.focus == was.keep && ops == 0,
                      "was \(lit(was.keep)) now \(lit(s.overlay.layers.focus)), \(ops) dimming operations")
            } else { check("focus unchanged since \(name)", false, "nothing remembered") }
        }
        if let name = a["textUnmoved"] as? String {
            // The line that held the caret (or the selection's start) when `name` was remembered is where it was in the window.
            if let at = remembered[name]?["anchor"], let was = remembered[name]?["anchorY"], let now = lineYInWindow(Int(at)) {
                check("text unmoved since \(name)", abs(now - was) < 1, "line at \(Int(at)) was \(was) now \(now)")
            } else { check("text unmoved since \(name)", false, "nothing remembered") }
        }
        if a["selectionDrawn"] as? Bool == true, let tv = textView {
            let (ok, detail) = selectionDrawnCheck(tv)
            check("selection drawn on every line it covers", ok, detail)
        }
        if let name = a["focusChanged"] as? String, let s = session {
            check("focus changed since \(name)", rememberedFocus[name].map { $0.keep != s.overlay.layers.focus } ?? false)
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
                case .code(let role)?: name = "code-\(role)"
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
            // (A string, or a list of them.)
            for c in (v["contains"] as? [String]) ?? (v["contains"] as? String).map({ [$0] }) ?? [] {
                check("file contains \(c.debugDescription)", disk.contains(c), String(disk.suffix(400)))
            }
            for c in (v["lacks"] as? [String]) ?? (v["lacks"] as? String).map({ [$0] }) ?? [] {
                check("file lacks \(c.debugDescription)", !disk.contains(c), String(disk.suffix(400)))
            }
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
                // (With the pictures' sizes, as every render for the page is made.)
                let base = p.renderOptions(standalone: false), sizes = p.pictureSizes, url = s.documentURL()
                let expected = s.coordinator.sync { $0.renderHtml(options: PreviewController.withPictureSizes(base, sizes: sizes, doc: $0, documentURL: url)) }
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
        if let v = a["pasted"] as? Bool { check("pasted \(v)", Self.pasted == v, Self.pasted.map { "\($0)" } ?? "pending") }
        if let v = a["assets"] as? Int {
            // Files in `<document>.assets` beside the current document.
            let url = document?.fileURL
            let dir = url.map { $0.deletingLastPathComponent().appendingPathComponent($0.deletingPathExtension().lastPathComponent + ".assets") }
            let files = dir.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            check("assets \(v)", files.count == v, "\(files)")
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
