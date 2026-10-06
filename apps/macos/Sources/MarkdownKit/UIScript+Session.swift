#if DEBUG || UI_SCRIPT
import AppKit

/// The harness's steps for reopening and quitting (M8g): `relaunch` ends the app through its normal quit path and has the
/// runner (`scripts/macos/ui-script.sh`) start it again against the same defaults, history and record, with the script
/// going on from the next step; `quit` asks the app to quit and answers the question "Quit Markdown?" through its API
/// (a panel nobody clicks); `session` writes and notes the record; the assertions compare the windows the app came back
/// with against what they were.
extension UIScriptRunner {
    // MARK: relaunching

    /// A script started again by `relaunch` goes on where the other left off: its step, its log, what it noted.
    func resume() {
        guard let path = Self.resumePath else { return }
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            record(["resume": "cannot read \(path)"], ok: false)
            return
        }
        index = o["index"] as? Int ?? 0
        failures = o["failures"] as? Int ?? 0
        log = o["log"] as? [[String: Any]] ?? []
        priorElapsed = (o["elapsed"] as? NSNumber)?.doubleValue ?? 0
        sessionMemory = o["memory"] as? [String: String] ?? [:]
        quitDialogs = o["dialogs"] as? [[String: Any]] ?? []
        record(["resumed": "step \(index)"], ok: true)
    }

    /// After a relaunch the windows of the record come back before the script goes on.
    func waitForRestoration(then: @escaping () -> Void) {
        guard Self.isResuming else { then(); return }
        waitFor(20, { SessionRestorer.current.map { !$0.isRestoring } ?? true }) { ok in
            later(0.6) {
                self.followFront()
                if let r = SessionRestorer.current {
                    self.record(["restored": r.restoredCount, "skipped": r.skipped, "windows": SessionRecorder.documentWindows().count], ok: ok)
                } else {
                    self.record(["restored": "nothing to restore"], ok: true)
                }
                then()
            }
        }
    }

    /// `{"relaunch": {"suppress": true, "expectDialog": false}}`: the app quits as ⌘Q does (the question is answered Quit,
    /// with its checkbox ticked for `suppress`), and is started again.
    func relaunchStep(_ r: [String: Any], then done: @escaping () -> Void) {
        let windows = SessionRecorder.documentWindows().count
        record(["relaunch": true, "windows": windows], ok: true)
        relaunching = true
        askQuit(answer: "quit", suppress: r["suppress"] as? Bool ?? false, expectDialog: r["expectDialog"] as? Bool)
        // Reached only when the app does not end at once.
        later(10) {
            self.relaunching = false
            self.record(["relaunch": "the app did not quit"], ok: false)
            self.finish()
        }
    }

    /// `{"quit": {"answer": "cancel", "suppress": true, "expectDialog": true}}`: ⌘Q. Cancel leaves the app running (the
    /// script goes on); Quit ends it, and the script with it.
    func quitStep(_ q: [String: Any], then done: @escaping () -> Void) {
        let answer = q["answer"] as? String ?? "quit"
        let before = quitDialogs.count
        askQuit(answer: answer, suppress: q["suppress"] as? Bool ?? false, expectDialog: q["expectDialog"] as? Bool)
        if answer == "cancel" {
            // Back here: the app did not quit.
            let asked = quitDialogs.count - before
            if let expect = q["expectDialog"] as? Bool { check("the question is \(expect ? "" : "not ")asked", (asked > 0) == expect, "asked \(asked) time(s)") }
            expectQuitDialog = nil
            record(["quit": "cancelled", "asked": asked, "windows": SessionRecorder.documentWindows().count], ok: asked > 0)
            later(0.3, done)
        } else {
            later(10) {
                self.record(["quit": "the app did not quit"], ok: false)
                self.finish()
            }
        }
    }

    private func askQuit(answer: String, suppress: Bool, expectDialog: Bool?) {
        quitAnswer = answer
        quitSuppress = suppress
        expectQuitDialog = expectDialog
        quitDialogsBefore = quitDialogs.count
        NSApp.terminate(nil)
    }

    /// The question is answered here, as a person's click would: Quit or Cancel, the checkbox ticked or not.
    func answerQuit(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let asked: [String: Any] = [
            "message": alert.messageText, "info": alert.informativeText, "buttons": alert.buttons.map(\.title),
            "default": alert.buttons.first { $0.keyEquivalent == "\r" }?.title ?? "", "suppression": alert.suppressionButton?.title ?? "",
            "windows": SessionRecorder.documentWindows().count,
        ]
        quitDialogs.append(asked)
        if quitSuppress { alert.suppressionButton?.state = .on }
        record(["quit question": asked, "answer": quitAnswer, "checkbox": quitSuppress], ok: true)
        return quitAnswer == "cancel" ? .alertSecondButtonReturn : .alertFirstButtonReturn
    }

    /// The app is ending (the question, if any, was answered Quit): a relaunch leaves its state for the runner, a quit is
    /// the end of the script.
    static func willTerminate() { running?.terminating() }

    private func terminating() {
        if let expect = expectQuitDialog {
            check("the question is \(expect ? "" : "not ")asked on quit", (quitDialogs.count > quitDialogsBefore) == expect, "asked \(quitDialogs.count - quitDialogsBefore) time(s)")
        }
        guard relaunching else {
            record(["quit": "the app quit"], ok: true)
            finish()
            return
        }
        let state: [String: Any] = ["index": index, "failures": failures, "log": log, "memory": sessionMemory, "dialogs": quitDialogs,
                                    "elapsed": Date().timeIntervalSince(Self.started) + priorElapsed]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("relaunch.json"))
        }
        FileHandle.standardError.write(Data("[ui-script] relaunch: the app ended after step \(index - 1)\n".utf8))
        exit(0)
    }

    // MARK: steps

    /// `{"session": {"write": true}}` writes the record now, `{"snapshot": "name"}` notes the windows as they are for
    /// `sameAs`, `{"deleteFile": "name.md"}` removes the script's copy of a file the windows have open.
    func sessionStep(_ s: [String: Any], then done: @escaping () -> Void) {
        let recorder = SessionRecorder.current ?? SessionRecorder(url: outDir.appendingPathComponent("session-unused.json"))
        if s["write"] as? Bool == true {
            let record = SessionRecorder.current?.writeNow()
            self.record(["session": "write", "windows": record?.windows.count ?? -1], ok: record != nil)
        } else if let name = s["snapshot"] as? String {
            let record = recorder.capture()
            sessionMemory[name] = (try? record.encoded()).flatMap { String(data: $0, encoding: .utf8) }
            self.record(["session": "snapshot \(name)", "windows": record.windows.count], ok: sessionMemory[name] != nil)
        } else if let name = s["deleteFile"] as? String {
            let url = outDir.appendingPathComponent("work", isDirectory: true).appendingPathComponent(name)
            let ok = (try? FileManager.default.removeItem(at: url)) != nil
            self.record(["session": "deleteFile \(name)"], ok: ok)
        } else {
            record(["session": s, "error": "unknown step"], ok: false)
        }
        done()
    }

    // MARK: assertions

    private func windowName(_ wc: EditorWindowController) -> String { wc.fileURL?.lastPathComponent ?? "untitled" }

    func sessionAssertions(_ a: [String: Any]) {
        let windows = SessionRecorder.documentWindows()
        if let n = a["windows"] as? Int { check("\(n) document window(s)", windows.count == n, "\(windows.map(windowName))") }
        if let names = a["files"] as? [String] {
            check("the windows, front to back, are \(names)", windows.map(windowName) == names, "\(windows.map(windowName))")
        }
        if let name = a["front"] as? String {
            let front = frontController
            check("the front window is \(name)", front.map(windowName) == name, "\(front.map(windowName) ?? "none")")
        }
        if let text = a["untitledText"] as? String {
            let found = windows.first { $0.fileURL == nil && $0.session.text == text }
            check("an untitled window holds the text", found != nil, "\(windows.filter { $0.fileURL == nil }.map { $0.session.text })")
            if let found, a["untitledEdited"] == nil { check("it is untitled and not saved anywhere", found.markdownDocument?.fileURL == nil, "") }
        }
        if let v = a["askBeforeQuitting"] as? Bool { check("askBeforeQuitting is \(v)", Settings.shared.askBeforeQuitting == v, "\(Settings.shared.askBeforeQuitting)") }
        if let v = a["reopenAtLaunch"] as? Bool { check("reopenAtLaunch is \(v)", Settings.shared.reopenAtLaunch == v, "\(Settings.shared.reopenAtLaunch)") }
        if let n = a["quitDialogs"] as? Int { check("the quit question was asked \(n) time(s) so far", quitDialogs.count == n, "\(quitDialogs.count)") }
        if let want = a["lastQuitDialog"] as? [String: Any] {
            let last = quitDialogs.last ?? [:]
            func canon(_ v: Any?) -> String {
                guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) else { return "\(String(describing: v))" }
                return String(decoding: d, as: UTF8.self)
            }
            let bad = want.filter { canon($0.value) != canon(last[$0.key]) }.keys.sorted()
            check("the last quit question is as expected", bad.isEmpty && !quitDialogs.isEmpty, "differs in \(bad): \(last)")
        }
        if let n = a["restored"] as? Int { check("\(n) window(s) were restored", SessionRestorer.current?.restoredCount == n, "\(SessionRestorer.current?.restoredCount ?? -1)") }
        if let n = a["skipped"] as? Int { check("\(n) record(s) were skipped", SessionRestorer.current?.skipped == n, "\(SessionRestorer.current?.skipped ?? -1)") }
        if let n = a["recordWindows"] as? Int {
            let record = SessionRecord.read(from: DocumentFileAccess.sessionRecordURL)
            check("the record has \(n) window(s)", record?.windows.count == n, "\(record?.windows.count ?? -1)")
        }
        if let want = a["settingsSwitches"] as? [Bool] {
            // The Settings window's first switches, in the order the form lists them: "Reopen documents at launch",
            // "Ask before quitting" (SwiftUI leaves a switch without a label of its own in the view tree).
            let found = settingsSwitches()
            check("Settings shows its first switches as \(want)", Array(found.prefix(want.count)) == want, "\(found)")
        }
        if let w = a["window"] as? [String: Any] { windowAssertions(w, windows) }
        if let name = a["sameAs"] as? String { sameAs(name) }
    }

    /// The state of the switches of the Settings window, in the order of the form.
    private func settingsSwitches() -> [Bool] {
        var out: [Bool] = []
        guard let root = SettingsWindowController.shared.window?.contentView else { return out }
        root.layoutSubtreeIfNeeded()
        func walk(_ v: NSView) {
            if let c = v as? NSControl, String(describing: type(of: c)).contains("Switch") { out.append(c.integerValue != 0) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    private func windowAssertions(_ w: [String: Any], _ windows: [EditorWindowController]) {
        let name = w["file"] as? String ?? "untitled"
        guard let wc = windows.first(where: { windowName($0) == name }), let state = wc.sessionState() else {
            check("window \(name) exists", false, "\(windows.map(windowName))")
            return
        }
        func has(_ what: String, _ ok: Bool, _ detail: String) { check("\(name): \(what)", ok, detail) }
        if let v = w["layout"] as? String { has("layout \(v)", state.layout == v, state.layout ?? "") }
        if let v = w["focus"] as? Bool { has("focus \(v)", state.focus == v, "\(String(describing: state.focus))") }
        if let v = w["notes"] as? Bool { has("notes mode \(v)", (state.notes != nil) == v && wc.inNotesMode == v && (wc.sidebar != nil) == v, "\(String(describing: state.notes)) sidebar \(wc.sidebar != nil)") }
        if let v = w["selection"] as? [String] { has("sidebar selection \(v)", state.notes?.selection == v, "\(state.notes?.selection ?? [])") }
        if let v = w["sort"] as? String { has("sort \(v)", state.notes?.sort == v, state.notes?.sort ?? "") }
        if let v = (w["sidebarWidth"] as? NSNumber)?.doubleValue {
            has("sidebar \(v) wide", abs((wc.sidebar?.view.frame.width.native ?? 0) - v) <= 1.5, "\(wc.sidebar?.view.frame.width ?? 0)")
        }
        if let c = w["column"] as? [String: Any] {
            if let v = c["shown"] as? Bool { has("column shown \(v)", wc.session.columnShown == v && (wc.sideColumn != nil) == v, "\(wc.session.columnShown)") }
            if let v = c["pane"] as? String { has("column shows \(v)", wc.session.columnPane.rawValue == v, wc.session.columnPane.rawValue) }
            if let v = (c["width"] as? NSNumber)?.doubleValue { has("column \(v) wide", abs((wc.columnView?.frame.width.native ?? 0) - v) <= 1.5, "\(wc.columnView?.frame.width ?? 0)") }
        }
        if let v = w["caret"] as? [Int] { has("caret \(v)", state.caret == v, "\(state.caret ?? [])") }
        if let v = (w["scrollCharacterAtLeast"] as? NSNumber)?.intValue { has("scrolled to a character past \(v)", (state.scrollCharacter ?? 0) >= v, "\(state.scrollCharacter ?? -1)") }
    }

    /// The windows now are the windows when `snapshot` noted them: the same files in the same order, each with the same
    /// frame, layout, mode, focus, sidebar and its state, column, caret and scroll position.
    private func sameAs(_ name: String) {
        guard let json = sessionMemory[name], let was = (json.data(using: .utf8)).flatMap(SessionRecord.decode) else {
            check("windows same as \(name)", false, "nothing noted as \(name)")
            return
        }
        let now = (SessionRecorder.current ?? SessionRecorder(url: outDir.appendingPathComponent("session-unused.json"))).capture()
        var bad: [String] = []
        if was.windows.count != now.windows.count { bad.append("window count \(was.windows.count) -> \(now.windows.count)") }
        if was.key != now.key { bad.append("key window \(String(describing: was.key)) -> \(String(describing: now.key))") }
        func near(_ a: Double?, _ b: Double?, _ tolerance: Double) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return abs(a - b) <= tolerance
        }
        func nearAll(_ a: [Double]?, _ b: [Double]?, _ tolerance: Double) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
        }
        for (i, pair) in zip(was.windows, now.windows).enumerated() {
            let (a, b) = pair
            func differ(_ what: String, _ ok: Bool, _ x: Any?, _ y: Any?) { if !ok { bad.append("window \(i) \(what): \(String(describing: x)) -> \(String(describing: y))") } }
            differ("file", a.file?.path == b.file?.path, a.file?.path, b.file?.path)
            differ("untitled text", a.untitledText == b.untitledText, a.untitledText?.prefix(20), b.untitledText?.prefix(20))
            differ("frame", nearAll(a.frame, b.frame, 1.5), a.frame, b.frame)
            differ("layout", a.layout == b.layout, a.layout, b.layout)
            differ("focus", a.focus == b.focus, a.focus, b.focus)
            differ("syntax", a.syntax == b.syntax, a.syntax, b.syntax)
            differ("authorship", a.authorship == b.authorship, a.authorship, b.authorship)
            differ("full screen", a.fullScreen == b.fullScreen, a.fullScreen, b.fullScreen)
            differ("column shown", a.column?.shown == b.column?.shown, a.column?.shown, b.column?.shown)
            differ("column pane", a.column?.pane == b.column?.pane, a.column?.pane, b.column?.pane)
            differ("column width", near(a.column?.width, b.column?.width, 1.5), a.column?.width, b.column?.width)
            differ("caret", a.caret == b.caret, a.caret, b.caret)
            differ("scroll character", a.scrollCharacter == b.scrollCharacter, a.scrollCharacter, b.scrollCharacter)
            differ("scroll into line", near(a.scrollInto, b.scrollInto, 2), a.scrollInto, b.scrollInto)
            differ("notes mode", (a.notes == nil) == (b.notes == nil), a.notes != nil, b.notes != nil)
            if let x = a.notes, let y = b.notes {
                differ("sidebar selection", x.selection == y.selection, x.selection, y.selection)
                differ("sidebar open folders", x.expanded == y.expanded, x.expanded, y.expanded)
                differ("sidebar tags", x.tags == y.tags, x.tags, y.tags)
                differ("sidebar search", x.search == y.search, x.search, y.search)
                differ("sidebar sort", x.sort == y.sort, x.sort, y.sort)
                differ("backlinks", x.backlinks == y.backlinks, x.backlinks, y.backlinks)
                differ("sidebar width", near(x.sidebarWidth, y.sidebarWidth, 1.5), x.sidebarWidth, y.sidebarWidth)
                differ("sidebar scroll", near(x.scroll, y.scroll, 1.5), x.scroll, y.scroll)
            }
        }
        check("windows same as \(name)", bad.isEmpty, bad.joined(separator: "; "))
    }
}
#endif
