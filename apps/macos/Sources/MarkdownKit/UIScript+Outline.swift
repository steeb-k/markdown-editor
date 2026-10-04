#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore

/// The harness's steps for the outline column. A click on it is the `click` step's (`at: outline`); what is here
/// shows and hides it, presses keys in it, waits for its headings and measures what an update costs the main thread.
extension UIScriptRunner {
    func outlineStep(_ o: [String: Any], then done: @escaping () -> Void) {
        guard let wc = notesController ?? controller else { record(["outline": "no window"], ok: false); done(); return }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        if let on = o["show"] as? Bool {
            // The View menu's item, as the window's action.
            if wc.session.outlineShown != on { _ = NSApp.sendAction(#selector(EditorWindowController.toggleOutline(_:)), to: wc, from: nil) }
            record(["outline": on ? "shown" : "hidden", "width": wc.outline?.view.frame.width ?? 0], ok: wc.session.outlineShown == on)
            done()
        } else if let n = o["waitEntries"] as? Int {
            let t0 = Date()
            waitFor(num("timeout") ?? 10, { wc.outline?.entries.count == n }) { ok in
                self.record(["outline": "waitEntries", "entries": wc.outline?.entries.count ?? -1, "ms": Int(Date().timeIntervalSince(t0) * 1000)], ok: ok)
                done()
            }
        } else if let key = o["key"] as? String {
            let codes: [String: (UInt16, String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
                                                      "return": (36, "\r"), "space": (49, " ")]
            guard let (code, chars) = codes[key], let w = wc.window else { record(["outline": "key", "error": "no key \(key)"], ok: false); done(); return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                    asEvent { w.sendEvent(e) }
                }
            }
            later(num("wait") ?? 0.2) {
                self.record(["outline": "key \(key)", "selected": wc.outline?.view.list.selectedRow ?? -1, "responder": self.outlineResponder(wc)], ok: true)
                done()
            }
        } else if let m = o["measure"] as? [String: Any] {
            outlineMeasure(m, wc, then: done)
        } else if let delta = num("dragDivider") {
            outlineDividerDrag(delta, wc, then: done)
        } else if o["focus"] as? Bool == true {
            // The keyboard to the list (a person's click on a row does this and also jumps).
            let ok = wc.outline.map { wc.window?.makeFirstResponder($0.view.list) ?? false } ?? false
            record(["outline": "focus"], ok: ok)
            done()
        } else if let name = o["fold"] as? String {
            // Folds (or unfolds, `"fold": "Title", "open": true`) the heading with that title, as its disclosure triangle does.
            guard let i = wc.outline?.entries.firstIndex(where: { $0.text == name }) else { record(["outline": "fold", "error": "no heading \(name)"], ok: false); done(); return }
            if o["open"] as? Bool == true { wc.outline?.expand(i) } else { wc.outline?.collapse(i) }
            later(0.1) {
                self.record(["outline": "fold \(name)", "rows": wc.outline?.visibleIndices.count ?? 0], ok: true)
                done()
            }
        } else {
            record(["outline": o, "error": "unknown step"], ok: false)
            done()
        }
    }

    /// The divider between the editor's pane and the column dragged by `delta` points (negative: to the left, the
    /// column wider): real mouse events through the window, as a person's drag, the tracking loop AppKit's own.
    private func outlineDividerDrag(_ delta: Double, _ wc: EditorWindowController, then done: @escaping () -> Void) {
        guard let host = wc.paneHost, let w = wc.window, let o = wc.outline else { record(["outline": "dragDivider", "error": "no column"], ok: false); done(); return }
        let before = o.view.frame.width
        makeKey(w) { [self] in
            let x = wc.root.frame.maxX + 0.5
            let start = host.convert(NSPoint(x: x, y: host.bounds.midY), to: nil)
            @MainActor func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            let hit = hitPlace(w, start)
            for (type, p) in [(NSEvent.EventType.leftMouseDown, start)] + (1...6).map({ (NSEvent.EventType.leftMouseDragged, NSPoint(x: start.x + CGFloat(delta) * CGFloat($0) / 6, y: start.y)) })
                + [(.leftMouseUp, NSPoint(x: start.x + CGFloat(delta), y: start.y))] {
                if let e = ev(type, p) { NSApp.postEvent(e, atStart: false) }
            }
            later(0.5) {
                self.record(["outline": "dragDivider", "from": before, "to": o.view.frame.width, "hit": hit, "remembered": wc.session.outlineWidth,
                             "default": Settings.shared.outlineWidth], ok: abs(o.view.frame.width - (before - CGFloat(delta))) < 2 || o.view.frame.width <= 160 || o.view.frame.width >= 480)
                done()
            }
        }
    }

    private func outlineResponder(_ wc: EditorWindowController) -> String {
        guard let r = wc.window?.firstResponder else { return "nil" }
        if r === wc.textView { return "text" }
        if let o = wc.outline?.view.list, r === o { return "outline" }
        if let v = r as? NSView, v === wc.previewController.webView || v.isDescendant(of: wc.previewController.webView) { return "preview" }
        return "\(type(of: r))"
    }

    /// Edits that change the headings, one at a time, each waited out: a letter typed into a heading (the same shape,
    /// one row redrawn) and a heading added and removed (the shape changes, the tree is rebuilt). Records what each
    /// update cost the main thread: the controller's own, and everything the window did when the headings arrived.
    private func outlineMeasure(_ m: [String: Any], _ wc: EditorWindowController, then done: @escaping () -> Void) {
        guard let tv = textView, let o = wc.outline else { record(["outline": "measure", "error": "no outline"], ok: false); done(); return }
        let count = (m["count"] as? Int) ?? 6
        let maxMs = (m["maxMs"] as? NSNumber)?.doubleValue ?? 10
        let needle = (m["needle"] as? String) ?? "Heading 500"
        // The heading the shape edits add (after the needle's line), and its text: a `####` after a `###` is a child of it
        // (the tree changes by a row); a `##` after a `##` with deeper headings under it takes them (the tree is reloaded).
        let added = (m["added"] as? String) ?? "## Added heading"
        var text: [Double] = [], shape: [Double] = []
        var arrival: [Double] = []
        var i = 0
        func step() {
            guard i < count * 2 else {
                let all = text + shape
                let worst = (all.max() ?? 0) * 1000
                let worstArrival = (arrival.max() ?? 0) * 1000
                self.record(["outline": "measure", "textEdits": text.count, "shapeEdits": shape.count,
                             "text_ms": text.map { ($0 * 10000).rounded() / 10 }, "shape_ms": shape.map { ($0 * 10000).rounded() / 10 },
                             "arrival_ms": arrival.map { ($0 * 10000).rounded() / 10 }, "max_ms": (worst * 10).rounded() / 10,
                             "max_arrival_ms": (worstArrival * 10).rounded() / 10, "rebuilds": o.rebuilds, "entries": o.entries.count, "added": added, "reloads": o.reloads],
                            ok: worstArrival < maxMs)
                done()
                return
            }
            let r = (tv.string as NSString).range(of: needle)
            guard r.location != NSNotFound else { self.record(["outline": "measure", "error": "no \(needle)"], ok: false); done(); return }
            let before = o.updates
            let structural = i % 2 == 1
            // The end of the heading's line (what earlier text edits added to it stays with it).
            let line = (tv.string as NSString).lineRange(for: r)
            let eol = line.location + (tv.string as NSString).substring(with: line).trimmingCharacters(in: .newlines).utf16.count
            tv.setSelectedRange(NSRange(location: structural ? eol : r.location + r.length, length: 0))
            self.asEvent {
                if structural {
                    // A new heading after this one; removed again by the next structural step (it holds the text it added).
                    tv.insertText("\n\n\(added) \(i)", replacementRange: tv.selectedRange())
                } else {
                    tv.insertText("x", replacementRange: tv.selectedRange())
                }
            }
            self.waitFor(5, { o.updates > before }) { ok in
                if ok {
                    (structural ? { shape.append(o.lastUpdateTime) } : { text.append(o.lastUpdateTime) })()
                    arrival.append(wc.lastOutlineArrival)
                } else {
                    self.record(["outline": "measure", "error": "no update for edit \(i)"], ok: false)
                }
                // Back to what it was, for the next round.
                if structural, let added = (tv.string as NSString).range(of: "\n\n\(added) \(i)") as NSRange?, added.location != NSNotFound {
                    self.asEvent { _ = tv.replaceThroughUndo(range: added, with: "") }
                }
                i += 1
                self.waitFor(5, { o.entries == wc.session.outlineEntries && wc.session.coordinator.isIdle }) { _ in later(0.4, step) }
            }
        }
        step()
    }

    func outlineAssertions(_ a: [String: Any]) {
        guard let wc = notesController ?? controller else { check("outline", false, "no window"); return }
        let o = wc.outline
        if let want = a["shown"] as? Bool {
            let shown = o != nil && o?.view.window != nil && wc.paneHost?.superview != nil && !(o?.view.isHidden ?? true)
            check("outline shown \(want)", shown == want, "outline \(o != nil)")
        }
        if let want = a["plain"] as? Bool {
            // The window is exactly the editor's own view (no column, no sidebar).
            let plain = wc.window?.contentView === wc.root && wc.paneHost == nil && wc.outline == nil && wc.history == nil
            check("plain layout \(want)", plain == want, "")
        }
        if let want = a["titles"] as? [String], let o {
            let got = o.visibleIndices.map { o.entries[$0].text }
            check("outline rows \(want)", got == want, "\(got)")
        }
        if let want = a["titlesStart"] as? [String], let o {
            let got = Array(o.visibleIndices.map { o.entries[$0].text }.prefix(want.count))
            check("outline rows start \(want)", got == want, "\(got)")
        }
        if let want = a["count"] as? Int { check("outline has \(want) headings", o?.entries.count == want, "\(o?.entries.count ?? -1)") }
        if let want = a["levels"] as? [Int], let o { check("outline levels \(want)", Array(o.entries.map { Int($0.level) }.prefix(want.count)) == want, "\(o.entries.map(\.level).prefix(want.count))") }
        if a.keys.contains("marked") {
            // The row that marks where the reader is: its heading's text (nil: none).
            let want = a["marked"] as? String
            var got: String?
            if let o, o.view.list.selectedRow >= 0, let node = o.view.list.item(atRow: o.view.list.selectedRow) as? OutlineNode { got = node.entry.text }
            check("outline marks \(want ?? "nothing")", got == want, "\(got ?? "nothing")")
        }
        if let want = a["width"] as? NSNumber, let o {
            check("outline is \(want) wide", abs(o.view.frame.width - CGFloat(truncating: want)) <= 1, "\(o.view.frame.width)")
        }
        if let want = a["responder"] as? String { check("keyboard in the \(want)", outlineResponder(wc) == want, outlineResponder(wc)) }
        if let h = a["editorTop"] as? String, let tv = textView {
            // The editor's first visible line is the heading's line (within a line's room).
            let anchor = wc.editorTopAnchor()
            let text = tv.string as NSString
            let line = anchor.map { text.substring(with: text.lineRange(for: NSRange(location: $0.character, length: 0))) } ?? ""
            check("editor's top line is \(h.debugDescription)", line.contains(h), line)
        }
        if let h = a["previewTop"] as? [String: Any], let name = h["heading"] as? String, let tol = (h["tolerance"] as? NSNumber)?.doubleValue,
           let entry = (o?.entries ?? wc.session.outlineEntries).first(where: { $0.text == name }) {
            let p = wc.previewController
            _ = p.waitUntilSettled(timeout: 10)
            let page = (p.evaluateSync("return __md.currentLine();") as? NSNumber)?.doubleValue ?? -1
            check("preview's top is at \(name.debugDescription) (line \(entry.line))", abs(page - Double(entry.line)) <= tol, "page at \(page)")
        }
        if a["markedAtPageTop"] as? Bool == true, let o {
            // In the Preview layout: the heading at the top of the page is the marked one.
            let page = (wc.previewController.evaluateSync("return __md.currentLine();") as? NSNumber)?.doubleValue ?? -1
            let want = OutlineModel.index(atLine: page, in: o.entries)
            var got: Int?
            if o.view.list.selectedRow >= 0, let node = o.view.list.item(atRow: o.view.list.selectedRow) as? OutlineNode { got = node.index }
            check("the marked heading is the page's top (line \(page))", want == got, "wanted \(String(describing: want)) marked \(String(describing: got))")
        }
        if let ms = (a["updateMs"] as? NSNumber)?.doubleValue {
            let t = wc.lastOutlineArrival * 1000
            check("the last outline update took under \(ms) ms of the main thread", t < ms, "\(t) ms")
        }
        if a["accessible"] as? Bool == true, let o {
            let l = o.view.list
            let ok = l.accessibilityRole() == .outline && l.accessibilityLabel() == "Outline"
            check("the list is an accessibility outline", ok, "\(String(describing: l.accessibilityRole())) \(l.accessibilityLabel() ?? "")")
        }
        if let w = (a["windowWidth"] as? NSNumber)?.doubleValue { check("the window is \(w) wide", abs(Double(wc.window?.frame.width ?? 0) - w) <= 1, "\(wc.window?.frame.width ?? 0)") }
        if let n = a["jumps"] as? Int { check("the outline made \(n) jumps", wc.jumps == n, "\(wc.jumps)") }
    }
}
#endif
