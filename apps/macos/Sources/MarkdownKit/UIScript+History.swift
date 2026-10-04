#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore

/// The harness's steps for the history panel and the snapshots behind it. The store is the script's own (a folder
/// beside its output); what the steps ask of it they ask of the service the documents record into.
extension UIScriptRunner {
    private var historyController: EditorWindowController? { frontController ?? controller }

    private func currentKey() -> String? { historyController?.markdownDocument?.historyKey }

    private func versionsNow() -> [HistoryVersion] {
        guard let key = currentKey() else { return [] }
        return HistoryService.current?.versionsNow(key: key) ?? []
    }

    func historyStep(_ h: [String: Any], then done: @escaping () -> Void) {
        guard let wc = historyController else { record(["history": "no window"], ok: false); done(); return }
        func num(_ k: String) -> Double? { (h[k] as? NSNumber)?.doubleValue }
        if let on = h["show"] as? Bool {
            // The View menu's item, as the window's action.
            if wc.session.historyShown != on { _ = NSApp.sendAction(#selector(EditorWindowController.toggleHistory(_:)), to: wc, from: nil) }
            later(0.3) {
                self.record(["history": on ? "shown" : "hidden", "width": wc.history?.view.frame.width ?? 0], ok: wc.session.historyShown == on)
                done()
            }
        } else if let n = h["waitVersions"] as? Int {
            let t0 = Date()
            waitFor(num("timeout") ?? 10, { self.versionsNow().count >= n }) { ok in
                self.record(["history": "waitVersions", "versions": self.versionsNow().count, "ms": Int(Date().timeIntervalSince(t0) * 1000)], ok: ok)
                done()
            }
        } else if let i = h["select"] as? Int {
            // The row of the i-th version (newest first), as a click on it does.
            guard let panel = wc.history, i < panel.versions.count else { record(["history": "select", "error": "no such version \(i)"], ok: false); done(); return }
            panel.select(id: panel.versions[i].id)
            let id = panel.versions[i].id
            waitFor(5, { panel.selectedID == id && panel.diffsShown > 0 }) { ok in
                later(0.2) {
                    self.record(["history": "select \(i)", "diff": panel.view.diff.string.prefix(300).description], ok: ok)
                    done()
                }
            }
        } else if h["restore"] != nil {
            guard let panel = wc.history, panel.selectedVersion != nil else { record(["history": "restore", "error": "nothing selected"], ok: false); done(); return }
            let before = wc.session.text
            panel.restoreSelected()
            waitFor(5, { wc.session.text != before }) { ok in
                later(0.3) {
                    self.record(["history": "restore", "undoName": wc.session.textView?.undoManager?.undoActionName ?? ""], ok: ok)
                    done()
                }
            }
        } else if h["copy"] != nil {
            guard let panel = wc.history, panel.selectedVersion != nil else { record(["history": "copy", "error": "nothing selected"], ok: false); done(); return }
            // To a pasteboard of the script's own, never the user's.
            let pb = NSPasteboard(name: NSPasteboard.Name("markdown-ui-script-history-\(UUID().uuidString)"))
            var done_ = false
            panel.copySelected(to: pb) { done_ = true }
            waitFor(5, { done_ }) { ok in
                self.copied = pb.string(forType: .string)
                self.record(["history": "copy", "length": (self.copied ?? "").utf8.count], ok: ok)
                done()
            }
        } else if let text = h["waitDiff"] as? String {
            guard let panel = wc.history else { record(["history": "waitDiff", "error": "no panel"], ok: false); done(); return }
            waitFor(num("timeout") ?? 5, { panel.view.diff.string.contains(text) }) { ok in
                self.record(["history": "waitDiff", "diff": panel.view.diff.string.prefix(400).description], ok: ok)
                done()
            }
        } else if let m = h["message"] as? String {
            // A snapshot with a message, as a milestone would be (the thinning never drops one).
            let id = HistoryService.current.flatMap { svc in currentKey().map { (svc, $0) } }
            guard let (svc, key) = id else { record(["history": "message", "error": "no store"], ok: false); done(); return }
            svc.record(key: key, text: wc.session.text, reason: .save, message: m) { id in
                self.record(["history": "message", "id": id.map { Int($0) } ?? -1], ok: id != nil)
                done()
            }
        } else if h["key"] != nil {
            record(["history": "key", "key": currentKey() ?? "none", "directory": HistoryService.current?.directory.path ?? "none"], ok: currentKey() != nil)
            done()
        } else {
            record(["history": h, "error": "unknown step"], ok: false)
            done()
        }
    }

    func historyAssertions(_ a: [String: Any]) {
        guard let wc = historyController else { check("history", false, "no window"); return }
        let versions = versionsNow()
        let reasons = versions.map { HistoryModel.reasonText($0.reason).lowercased() }
        if let n = a["count"] as? Int { check("history has \(n) version(s)", versions.count == n, "\(versions.count): \(reasons)") }
        if let r = a["reasons"] as? [String] { check("history reasons \(r)", Array(reasons.prefix(r.count)) == r, "\(reasons)") }
        if let r = a["latestReason"] as? String { check("latest snapshot is a \(r)", reasons.first == r, "\(reasons)") }
        if let m = a["messages"] as? [String] {
            let got = versions.compactMap(\.message)
            check("snapshots with a message \(m)", got == m, "\(got)")
        }
        if a["latestIsTheText"] as? Bool == true {
            let key = currentKey(), id = versions.first?.id
            let text = key.flatMap { k in id.flatMap { HistoryService.current?.textNow(key: k, id: $0) } }
            check("the latest snapshot is the text in the window", text == wc.session.text, "snapshot \(text?.count ?? -1) chars, window \(wc.session.text.count)")
        }
        if let s = a["latestSummary"] as? String, let v = versions.first { check("latest snapshot's summary \(s)", HistoryModel.summary(v) == s, HistoryModel.summary(v)) }
        if let want = a["textOfVersion"] as? [String: Any], let i = want["index"] as? Int, i < versions.count, let key = currentKey() {
            let text = HistoryService.current?.textNow(key: key, id: versions[i].id) ?? ""
            if let c = want["contains"] as? String { check("version \(i) holds \(c.debugDescription)", text.contains(c), text) }
            if let c = want["lacks"] as? String { check("version \(i) lacks \(c.debugDescription)", !text.contains(c), text) }
        }
        if let layout = a["store"] as? Bool, layout, let key = currentKey(), let dir = HistoryService.current?.directory {
            // A person can recover without the app: the folder of the key holds index.json and one .md per distinct text.
            let folders = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            var found = false
            var detail = "\(folders)"
            for f in folders {
                let index = dir.appendingPathComponent(f).appendingPathComponent("index.json")
                guard let data = try? Data(contentsOf: index), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["key"] as? String == key else { continue }
                found = true
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(f).path)) ?? []
                let texts = files.filter { $0.hasSuffix(".md") }
                let shas = Set((obj["entries"] as? [[String: Any]] ?? []).compactMap { $0["sha"] as? String })
                found = texts.count == shas.count && Set(texts.map { String($0.dropLast(3)) }) == shas
                detail = "files \(files) shas \(shas.count)"
            }
            check("the store is index.json and one text file per distinct text", found, detail)
        }
        if let want = a["panelShown"] as? Bool {
            let shown = wc.history != nil && wc.history?.view.window != nil && wc.paneHost?.superview != nil
            check("history panel shown \(want)", shown == want, "history \(wc.history != nil) shown flag \(wc.session.historyShown)")
        }
        if let want = a["outlineHidden"] as? Bool { check("outline hidden \(want)", (wc.outline == nil) == want && (wc.session.outlineShown == false) == want, "outline \(wc.outline != nil)") }
        if let want = a["rows"] as? Int, let panel = wc.history {
            let n = panel.items.filter { if case .version = $0 { return true } else { return false } }.count
            check("history panel lists \(want) version(s)", n == want, "\(n)")
        }
        if let want = a["days"] as? [String], let panel = wc.history {
            let got = panel.items.compactMap { item -> String? in if case .day(let t) = item { return t } else { return nil } }
            check("history panel groups \(want)", got == want, "\(got)")
        }
        if let want = a["selected"] as? Bool, let panel = wc.history { check("a version is selected \(want)", (panel.selectedVersion != nil) == want) }
        if let t = a["diffContains"] as? String, let panel = wc.history { check("the diff shows \(t.debugDescription)", panel.view.diff.string.contains(t), panel.view.diff.string) }
        if let t = a["diffLacks"] as? String, let panel = wc.history { check("the diff lacks \(t.debugDescription)", !panel.view.diff.string.contains(t), panel.view.diff.string) }
        if a["diffColours"] as? Bool == true, let panel = wc.history {
            // Removed lines in the theme's reference colour, added in its AI colour, the rest secondary.
            let p = wc.session.appearance.palette
            let storage = panel.view.diff.textStorage ?? NSTextStorage()
            let text = storage.string as NSString
            var ok = storage.length > 0
            var detail = ""
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, _ in
                guard let line, !line.isEmpty else { return }
                let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                let want: NSColor? = line.hasPrefix("\u{2212} ") ? p.authorReference : line.hasPrefix("+ ") ? p.authorAI : nil
                if let want, let c = color {
                    let a = c.usingColorSpace(.sRGB), b = want.usingColorSpace(.sRGB)
                    let same = abs((a?.redComponent ?? -1) - (b?.redComponent ?? -2)) < 0.01 && abs((a?.greenComponent ?? -1) - (b?.greenComponent ?? -2)) < 0.01
                        && abs((a?.blueComponent ?? -1) - (b?.blueComponent ?? -2)) < 0.01 && (a?.alphaComponent ?? 1) < 1
                    if !same { ok = false; detail += "\(line.prefix(20)): \(String(describing: color)) " }
                }
            }
            check("the diff is coloured with the theme's reference and AI colours, muted", ok, detail)
        }
        if a["accessibleRows"] as? Bool == true, let panel = wc.history {
            var ok = true
            var detail = ""
            for (i, item) in panel.items.enumerated() {
                guard case .version = item, let cell = panel.view.list.view(atColumn: 0, row: i, makeIfNecessary: true) as? HistoryRowView else { continue }
                if cell.accessibilityLabel()?.isEmpty != false || cell.accessibilityRole() != .row { ok = false; detail += "row \(i) " }
            }
            check("every version row has a role and a label", ok && panel.view.list.accessibilityLabel() == "History", detail)
        }
        if let name = a["undoName"] as? String { check("undo is named \(name)", wc.session.textView?.undoManager?.undoActionName == name, wc.session.textView?.undoManager?.undoActionName ?? "") }
        if let t = a["copied"] as? String { check("Copy put the version's text on the pasteboard", copied == t, copied ?? "nil") }
        if let i = a["copiedIsVersion"] as? Int, i < versions.count, let key = currentKey() {
            let text = HistoryService.current?.textNow(key: key, id: versions[i].id)
            check("Copy put version \(i)'s text on the pasteboard", copied != nil && copied == text, "copied \(copied?.count ?? -1) chars, version \(text?.count ?? -1)")
        }
        if let want = a["changeBar"] as? Bool { check("the bar about another app's change shown \(want)", (wc.changeBar?.superview != nil) == want, "\(wc.changeBar != nil)") }
        if let want = a["changeBarMentions"] as? String { check("the bar says \(want.debugDescription)", wc.changeBar?.label.stringValue.contains(want) == true, wc.changeBar?.label.stringValue ?? "") }
    }

    /// Where `workFile` paths are: beside the output, in `work`.
    func workFileURL(_ path: String) -> URL { outDir.appendingPathComponent("work", isDirectory: true).appendingPathComponent(path) }

    func fileAssertions(_ f: [String: Any]) {
        let url: URL?
        if let path = f["work"] as? String { url = workFileURL(path) } else { url = document?.fileURL }
        guard let url else { check("file", false, "no file"); return }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        if let want = f["exists"] as? Bool { check("\(url.lastPathComponent) exists \(want)", FileManager.default.fileExists(atPath: url.path) == want, url.path) }
        if let c = f["contains"] as? String { check("\(url.lastPathComponent) holds \(c.debugDescription)", text.contains(c), String(text.prefix(300))) }
        if let c = f["lacks"] as? String { check("\(url.lastPathComponent) lacks \(c.debugDescription)", !text.contains(c), String(text.prefix(300))) }
        if f["equalsText"] as? Bool == true, let d = document {
            // The bytes on disk are the window's text, as encoded for the file.
            check("\(url.lastPathComponent) on disk is the text in the window", data == d.saveSnapshot().encoded(), "disk \(data.count) bytes, window \(d.session.text.utf8.count) chars")
        }
        if let t = f["startsWith"] as? String { check("\(url.lastPathComponent) starts with \(t.debugDescription)", text.hasPrefix(t), String(text.prefix(60))) }
    }
}
#endif

#if DEBUG || UI_SCRIPT
extension UIScriptRunner {
    /// The steps for autosave: the pause it waits for, waiting for the file, and closing a window the way its red button does.
    func autosaveStep(_ a: [String: Any], then done: @escaping () -> Void) {
        func num(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
        if let d = num("delay") {
            MarkdownDocument.autosaveDelay = d
            record(["autosave": "delay \(d)"], ok: true)
            done()
        } else if a["waitClean"] != nil {
            // The document is written and no longer edited (the pause has passed and the write finished).
            guard let doc = document else { record(["autosave": "waitClean", "error": "no document"], ok: false); done(); return }
            let t0 = Date()
            waitFor(num("timeout") ?? 8, { !doc.isDocumentEdited }) { ok in
                self.record(["autosave": "waitClean", "ms": Int(Date().timeIntervalSince(t0) * 1000), "edited": doc.isDocumentEdited], ok: ok)
                done()
            }
        } else if let text = a["waitFile"] as? String {
            // The document's file holds `text` (a write that took place).
            guard let url = document?.fileURL else { record(["autosave": "waitFile", "error": "no file"], ok: false); done(); return }
            let t0 = Date()
            waitFor(num("timeout") ?? 8, { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(text) }) { ok in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                // `minMs`, `maxMs`: when the write may come (2 s after the last keystroke, not before).
                let inTime = ms >= Int(num("minMs") ?? 0) && ms <= Int(num("maxMs") ?? 100_000)
                self.record(["autosave": "waitFile", "ms": ms, "minMs": num("minMs") ?? 0, "maxMs": num("maxMs") ?? 0], ok: ok && inTime)
                done()
            }
        } else if a["waitTitled"] != nil {
            // An untitled document drafted into the library: it has a file.
            guard let doc = document else { record(["autosave": "waitTitled", "error": "no document"], ok: false); done(); return }
            let t0 = Date()
            waitFor(num("timeout") ?? 8, { doc.fileURL != nil }) { ok in
                later(0.3) {
                    self.record(["autosave": "waitTitled", "ms": Int(Date().timeIntervalSince(t0) * 1000), "file": doc.fileURL?.path ?? ""], ok: ok)
                    done()
                }
            }
        } else if a["closeWindow"] != nil {
            // Closing as the red button does: the window asks its document (`canClose`), which writes first; a question
            // would show as a sheet.
            guard let w = window, let doc = document else { record(["autosave": "closeWindow", "error": "no window"], ok: false); done(); return }
            let before = NSDocumentController.shared.documents.count
            w.performClose(nil)
            waitFor(num("timeout") ?? 4, { NSDocumentController.shared.documents.count < before || w.attachedSheet != nil }) { _ in
                let sheet = w.attachedSheet != nil
                self.record(["autosave": "closeWindow", "closed": NSDocumentController.shared.documents.count < before, "sheet": sheet,
                             "document": doc.displayName ?? ""], ok: true)
                if !sheet { self.document = nil; self.followFront() }
                done()
            }
        } else {
            record(["autosave": a, "error": "unknown step"], ok: false)
            done()
        }
    }
}
#endif
