#if DEBUG || UI_SCRIPT
import AppKit
import WebKit

/// Real mouse events: clicks and drags posted to the application's event queue, so that they go
/// through `NSApplication.sendEvent` and `NSWindow.sendEvent` (hit-testing, first-responder changes,
/// the text view's own tracking loop) exactly as the window server's would. The other steps call
/// handlers directly and cannot see a view that swallows a click.
extension UIScriptRunner {
    /// The window in front of the script (the editor window in front).
    private var clickController: EditorWindowController? { notesController ?? controller }

    /// Where a click goes, in window coordinates, and what it is over.
    private func clickTarget(_ c: [String: Any]) -> (point: NSPoint, location: Int?, detail: String)? {
        guard let wc = clickController else { return nil }
        let at = c["at"] as? String ?? "text"
        let fx = (c["x"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0.5
        let fy = (c["y"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0.5
        func inside(_ v: NSView) -> NSPoint {
            v.convert(NSPoint(x: v.bounds.minX + v.bounds.width * fx, y: v.bounds.minY + v.bounds.height * fy), to: nil)
        }
        switch at {
        case "text":
            let tv = wc.textView
            guard let needle = c["needle"] as? String, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
            let r = (tv.string as NSString).range(of: needle)
            guard r.location != NSNotFound else { return nil }
            let loc = r.location + (c["offset"] as? Int ?? 0)
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(tv.string.utf16.count, loc + 1)))
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1), actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            // The left quarter of the character: the caret goes before it.
            let p = NSPoint(x: rect.minX + max(1, rect.width * 0.25), y: rect.midY)
            return (tv.convert(p, to: nil), loc, "\(needle)+\(c["offset"] as? Int ?? 0)")
        case "badge":
            // A point by the language badge of the block holding `needle`: `side` `left` or `right` (`gap` points beside the
            // pill, on its line), `below` (under it), `centre` (on it: a click there opens the menu, so `probe` it).
            let tv = wc.textView
            guard let needle = c["needle"] as? String, let b = badge(of: needle, ignoringCaret: c["ignoringCaret"] as? Bool ?? false) else { return nil }
            let f = tv.viewFrame(of: b)
            let gap = (c["gap"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 6
            let side = c["side"] as? String ?? "left"
            let v: NSPoint = switch side {
            case "right": NSPoint(x: f.maxX + gap, y: f.midY)
            case "below": NSPoint(x: f.midX, y: f.maxY + gap)
            case "centre": NSPoint(x: f.midX, y: f.midY)
            default: NSPoint(x: f.minX - gap, y: f.midY)
            }
            return (tv.convert(v, to: nil), tv.characterIndexForInsertion(at: v), "badge \(side) of \(needle)")
        case "outline", "outlineDisclosure":
            // A row of the outline column (`row`: among the rows showing, or `text`: a heading's title); the
            // disclosure triangle is at the row's indent.
            guard let o = wc.outline else { return nil }
            let list = o.view.list
            var row = c["row"] as? Int ?? 0
            if let text = c["text"] as? String {
                guard let i = o.entries.firstIndex(where: { $0.text == text }), let r = o.row(of: i) else { return nil }
                row = r
            }
            guard row < list.numberOfRows else { return nil }
            let rr = list.rect(ofRow: row)
            let x = at == "outline" ? rr.maxX - 24 : list.frameOfOutlineCell(atRow: row).midX
            return (list.convert(NSPoint(x: x, y: rr.midY), to: nil), nil, "\(at) row \(row)")
        case "toolbar":
            return (inside(wc.toolbar), nil, "toolbar")
        case "preview":
            return (inside(wc.previewController.webView), nil, "preview")
        case "search":
            guard let bar = wc.sidebar?.view else { return nil }
            return (inside(bar.searchField), nil, "search")
        case "sidebar":
            guard let bar = wc.sidebar?.view else { return nil }
            let outline = bar.outline
            let row = c["row"] as? Int ?? 0
            guard row < outline.numberOfRows else { return nil }
            let rr = outline.rect(ofRow: row)
            return (outline.convert(NSPoint(x: rr.midX, y: rr.midY), to: nil), nil, "row \(row)")
        case "checkbox":
            // The n-th task checkbox of Live mode, where it is drawn.
            let tv = wc.textView
            guard let lm = tv.layoutManager as? EditorLayoutManager, let tc = tv.textContainer else { return nil }
            let n = c["index"] as? Int ?? 0
            let boxes = lm.live.decorations.filter { if case .checkbox = $0.kind { return true } else { return false } }
            guard n < boxes.count, let f = lm.checkboxFrame(of: boxes[n], in: tc) else { return nil }
            let o = tv.textContainerOrigin
            return (tv.convert(NSPoint(x: f.midX + o.x, y: f.midY + o.y), to: nil), nil, "checkbox \(n)")
        case "window":
            // A point of the window: `x`, `y` as fractions of its size, or points (above 1) from its bottom left.
            guard let w = wc.window else { return nil }
            let px = fx <= 1 ? w.frame.width * fx : fx, py = fy <= 1 ? w.frame.height * fy : fy
            let p = NSPoint(x: px, y: py)
            let tv = wc.textView
            let index = tv.characterIndexForInsertion(at: tv.convert(p, from: nil))
            return (p, index, "window \(Int(px)),\(Int(py))")
        case "title":
            // The app's own title (its name, and "Edited"): `x` a fraction across it.
            let tv = wc.titleView
            let f = tv.titleFrame
            guard !tv.isHidden, f.width > 0 else { return nil }
            return (tv.convert(NSPoint(x: f.minX + f.width * fx, y: f.midY), to: nil), nil, "title")
        case "titlebar":
            guard let w = wc.window else { return nil }
            let bar = w.frame.height - w.contentLayoutRect.height
            return (NSPoint(x: w.frame.width * fx, y: w.frame.height - bar / 2), nil, "titlebar")
        default:
            return nil
        }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in w: NSWindow, count: Int, mods: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// The class of what the window's frame view hit-tests at a point: the view AppKit gives the click to.
    func hitName(_ w: NSWindow, _ p: NSPoint) -> String {
        guard let frame = w.contentView?.superview, let hit = frame.hitTest(p) else { return "nil" }
        return "\(type(of: hit))"
    }

    /// Which part of the window a point hit-tests to: `text`, `toolbar`, `preview`, `sidebar`, `divider`, `titlebar`
    /// (anything outside the content view) or `other`.
    func hitPlace(_ w: NSWindow, _ p: NSPoint) -> String {
        guard let wc = clickController, let content = w.contentView, let hit = content.superview?.hitTest(p) else { return "nil" }
        if hit === wc.textView || hit.isDescendant(of: wc.textView) { return "text" }
        if hit.isDescendant(of: wc.toolbar) { return "toolbar" }
        if hit.isDescendant(of: wc.previewController.webView) { return "preview" }
        if let bar = wc.sidebar?.view, hit.isDescendant(of: bar) { return hit === bar.band ? "titlebar" : "sidebar" }
        if let column = wc.sideColumn?.view, hit.isDescendant(of: column) { return hit === column.band ? "titlebar" : "outline" }
        if hit === wc.splitView { return "divider" }
        if !hit.isDescendant(of: content) || hit === wc.titlebarBand || hit === wc.titleView { return "titlebar" }
        return "other"
    }

    private func responderName(_ w: NSWindow) -> String {
        guard let r = w.firstResponder else { return "nil" }
        if let wc = clickController {
            if r === wc.textView { return "text" }
            if let v = r as? NSView, v === wc.previewController.webView || v.isDescendant(of: wc.previewController.webView) { return "preview" }
            if let v = r as? NSView, let bar = wc.sidebar?.view, v.isDescendant(of: bar) { return "sidebar" }
            // A field editor stands for its control.
            if let tv = r as? NSTextView, tv.isFieldEditor, let bar = wc.sidebar?.view,
               let owner = tv.delegate as? NSView, owner.isDescendant(of: bar) { return "sidebar" }
        }
        return "\(type(of: r))"
    }

    /// `{"click": {"at": "text", "needle": "word", "offset": 1, "count": 1, "mods": ["cmd"], "expectSelection": [l, n],
    /// "expectResponder": "text", "expectHit": "EditorTextView"}}`: one click (or `count` clicks in a row: a double-click,
    /// a triple-click) posted to the event queue. `at` is `text` (a character of the text), `checkbox` (`index`), `preview`,
    /// `sidebar` (a `row`), `search` (the sidebar's field), `window` (`x`, `y`: fractions, or points from the bottom left;
    /// `expectCaret`: the caret lands at the character there) or `titlebar` (`x`, `y`: fractions of the view). Every click
    /// logs the view the window hit-tests at its point (`hit`, and `hitIn`: `text`, `toolbar`, `preview`, `sidebar`,
    /// `divider`, `titlebar`, `other`), the first responder and the selection after it. `"probe": true` only logs (and
    /// checks) where the click would land, sending nothing; `toolbar` is a target for that.
    func clickStep(_ c: [String: Any], then done: @escaping () -> Void) {
        guard let w = clickController?.window, let (p, loc, detail) = clickTarget(c) else {
            record(["click": c, "error": "no target"], ok: false)
            done()
            return
        }
        let count = max(1, c["count"] as? Int ?? 1)
        var mods: NSEvent.ModifierFlags = []
        for m in (c["mods"] as? [String]) ?? [] {
            switch m {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "option": mods.insert(.option)
            default: break
            }
        }
        // A click on a window of an app in the background only brings it forward (the view gets it only if it
        // accepts the first mouse): the script's window is made key first, as a person's earlier click would have.
        makeKey(w) { [self] in
            clickNow(c, w, p, loc, detail, count, mods, then: done)
        }
    }

    /// The app active and the window key, if the system lets it be (a script started from a terminal in the
    /// background may not get there; every click logs whether it was).
    func makeKey(_ w: NSWindow, then: @escaping () -> Void) {
        if w.isKeyWindow && NSApp.isActive { then(); return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        waitFor(1, { w.isKeyWindow && NSApp.isActive }) { _ in then() }
    }

    private func clickNow(_ c: [String: Any], _ w: NSWindow, _ p: NSPoint, _ loc: Int?, _ detail: String, _ count: Int,
                          _ mods: NSEvent.ModifierFlags, then done: @escaping () -> Void) {
        let hit = hitName(w, p)
        let place = hitPlace(w, p)
        var frames: [String: String] = [:]
        if hit != "EditorTextView", c["at"] as? String ?? "text" == "text", let wc = clickController {
            // Where the editor's views are, in the window: what the click missed.
            let views: [(String, NSView)] = [("scroll", wc.scrollView), ("clip", wc.scrollView.contentView), ("text", wc.textView)]
            for (name, v) in views { frames[name] = NSStringFromRect(v.convert(v.bounds, to: nil)) }
            frames["clipBounds"] = NSStringFromRect(wc.scrollView.contentView.bounds)
            frames["insets"] = "\(wc.scrollView.contentInsets.top) \(wc.scrollView.contentInsets.bottom)"
        }
        if c["probe"] as? Bool == true {
            // Only where the click would land (a click on the formatting bar would format the text). `canMoveWindow`: the
            // view there lets a press move the window, the condition AppKit puts on a title-bar drag (which the window
            // server then performs with the real pointer, so posted drag events cannot show it).
            // (AppKit's own buttons in the row, the document's icon and "Edited", are exempt: they are the title's.)
            let canMove = w.contentView?.superview?.hitTest(p)?.mouseDownCanMoveWindow ?? false
            let appKits = hit.hasPrefix("NSTheme") && hit.hasSuffix("Button")
            record(["probe": detail, "hit": hit, "hitIn": place, "at": NSStringFromPoint(p), "canMoveWindow": canMove],
                   ok: (c["expectHitIn"] as? String).map { $0 == place } ?? true && (c["expectCanMoveWindow"] as? Bool).map { $0 == canMove || appKits } ?? true)
            done()
            return
        }
        if let tv = clickController?.textView, tv.codeBadge(at: tv.convert(p, from: nil)) != nil {
            // A click there pops the language menu up, which tracks until it is closed: `codeBadge` with `real` does that.
            record(["click": detail, "error": "the point is on a language badge that is showing (use codeBadge real)"], ok: false)
            done()
            return
        }
        let frameBefore = w.frame
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        for k in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = mouse(type, p, in: w, count: k, mods: mods) { NSApp.postEvent(e, atStart: false) }
            }
        }
        later(c["wait"] as? Double ?? 0.3) { [self] in
            let sel = clickController?.textView.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
            let responder = responderName(w)
            var ok = true
            var entry: [String: Any] = ["click": detail, "count": count, "hit": hit, "hitIn": place, "at": NSStringFromPoint(p),
                                        "responder": responder, "selection": [sel.location, sel.length], "key": w.isKeyWindow,
                                        "active": NSApp.isActive]
            if !frames.isEmpty { entry["frames"] = frames }
            if let want = c["expectHit"] as? String { ok = ok && hit == want }
            if let want = c["expectHitIn"] as? String { ok = ok && place == want }
            if c["expectWindowAction"] as? Bool == true {
                // The title bar's double-click does what System Settings says (zoom, minimize, nothing).
                let setting = TitlebarDoubleClick.setting()
                entry["frame"] = [NSStringFromRect(frameBefore), NSStringFromRect(w.frame)]
                entry["titlebarSetting"] = "\(setting)"
                switch setting {
                case .zoom: ok = ok && w.frame != frameBefore
                case .minimize: ok = ok && w.isMiniaturized
                case .nothing: ok = ok && w.frame == frameBefore
                }
                if w.isMiniaturized { w.deminiaturize(nil) }
            }
            if c["expectRename"] as? Bool == true {
                // A double-click on the title's name: AppKit's rename popover comes up (a window of its own, by the title),
                // and the window neither zooms nor moves. The popover is then dismissed with Escape, renaming nothing.
                let appeared = NSApp.windows.filter { $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0)) }
                let title = clickController.map { $0.titleView.convert($0.titleView.titleFrame, to: nil) } ?? .zero
                let titleOnScreen = w.convertToScreen(title)
                entry["appeared"] = appeared.map { "\(Swift.type(of: $0)) \(NSStringFromRect($0.frame))" }
                entry["renames"] = clickController?.titleRenames ?? -1
                entry["titleOnScreen"] = NSStringFromRect(titleOnScreen)
                entry["frame"] = [NSStringFromRect(frameBefore), NSStringFromRect(w.frame)]
                // Placed by the title: its horizontal span overlaps the title's, and it hangs just below the title bar.
                let byTitle = appeared.contains { $0.frame.minX < titleOnScreen.maxX + 40 && $0.frame.maxX > titleOnScreen.minX - 40
                    && $0.frame.maxY <= titleOnScreen.maxY + 40 && $0.frame.maxY >= w.frame.maxY - 200 }
                entry["byTitle"] = byTitle
                ok = ok && !appeared.isEmpty && w.frame == frameBefore && byTitle
                for p in appeared {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: p.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: 53) { NSApp.postEvent(e, atStart: false) }
                    }
                }
            }
            if let want = c["expectResponder"] as? String { ok = ok && responder == want }
            if let want = c["expectSelection"] as? [Int], want.count == 2 {
                ok = ok && sel.location == want[0] && sel.length == want[1]
            } else if c["at"] as? String ?? "text" == "text" || c["expectCaret"] as? Bool == true, count == 1, mods.isEmpty, let loc {
                // A plain click puts the caret before the clicked character.
                entry["expected"] = [loc, 0]
                ok = ok && sel.location == loc && sel.length == 0
            }
            if let want = c["expectSelectedText"] as? String, let tv = clickController?.textView {
                let got = (tv.string as NSString).substring(with: sel)
                entry["selectedText"] = got
                ok = ok && got == want
            }
            record(entry, ok: ok)
            done()
        }
    }

    /// `{"drag": {"from": "needle", "to": "needle", "toOffset": 0, "expectSelectedText": "..."}}`: a press over one
    /// character, the pointer dragged in steps to another, released.
    func dragStep(_ d: [String: Any], then done: @escaping () -> Void) {
        guard let w = clickController?.window,
              let from = d["from"] as? String, let to = d["to"] as? String,
              let (a, la, _) = clickTarget(["needle": from, "offset": d["fromOffset"] as? Int ?? 0]),
              let (b, lb, _) = clickTarget(["needle": to, "offset": d["toOffset"] as? Int ?? 0]) else {
            record(["drag": d, "error": "no target"], ok: false)
            done()
            return
        }
        makeKey(w) { [self] in dragNow(d, w, a, b, la, lb, from, to, then: done) }
    }

    private func dragNow(_ d: [String: Any], _ w: NSWindow, _ a: NSPoint, _ b: NSPoint, _ la: Int?, _ lb: Int?,
                         _ from: String, _ to: String, then done: @escaping () -> Void) {
        let hit = hitName(w, a)
        if let e = mouse(.leftMouseDown, a, in: w, count: 1, mods: []) { NSApp.postEvent(e, atStart: false) }
        let steps = 6
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            if let e = mouse(.leftMouseDragged, p, in: w, count: 1, mods: []) { NSApp.postEvent(e, atStart: false) }
        }
        if let e = mouse(.leftMouseUp, b, in: w, count: 1, mods: []) { NSApp.postEvent(e, atStart: false) }
        later(0.4) { [self] in
            let tv = clickController?.textView
            let sel = tv?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
            let got = tv.map { ($0.string as NSString).substring(with: sel) } ?? ""
            var ok = responderName(w) == "text"
            if let la, let lb { ok = ok && sel.location == min(la, lb) && NSMaxRange(sel) == max(la, lb) }
            if let want = d["expectSelectedText"] as? String { ok = ok && got == want }
            record(["drag": "\(from) -> \(to)", "hit": hit, "selection": [sel.location, sel.length], "selectedText": got,
                    "responder": responderName(w)], ok: ok)
            done()
        }
    }

    /// `{"contextMenu": {"needle": "word", "offset": 1, "select": [loc, len], "has": ["Paste As", "Mark As"], "lacks": [...],
    /// "choose": "Mark This Passage As > Reference", "expectSelection": [loc, len]}}`: a right-click on a character. The real
    /// `rightMouseDown` is built for the window's point, hit-tested like a click, and handed to the text view's `menu(for:)`
    /// (what AppKit calls from `rightMouseDown`); posting it would start the menu's tracking loop, which blocks until a
    /// mouse button the harness cannot press is released. The menu's items are validated (`update()`) and `choose` (titles
    /// joined by `>`) performs the item's own action, as the click on it would. `has` and `lacks` name top-level items.
    func contextMenuStep(_ d: [String: Any], then done: @escaping () -> Void) {
        guard let wc = clickController, let w = wc.window, let (p, _, detail) = clickTarget(d) else {
            record(["contextMenu": d, "error": "no target"], ok: false)
            done()
            return
        }
        makeKey(w) { [self] in
            let tv = wc.textView
            if let sel = d["select"] as? [Int], sel.count == 2 { tv.setSelectedRange(NSRange(location: sel[0], length: sel[1])) }
            let hit = hitName(w, p)
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = tv.menu(for: e) else {
                record(["contextMenu": detail, "error": "no menu"], ok: false)
                done()
                return
            }
            var ok = hit == "EditorTextView"
            let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            for t in d["has"] as? [String] ?? [] { ok = ok && titles.contains(t) }
            for t in d["lacks"] as? [String] ?? [] { ok = ok && !titles.contains(t) }
            var entry: [String: Any] = ["contextMenu": detail, "hit": hit, "items": titles]
            for item in menu.items { item.submenu?.update() }
            if let path = d["choose"] as? String {
                var level = menu
                var found: NSMenuItem?
                for title in path.components(separatedBy: ">").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    found = level.items.first { $0.title == title }
                    if let sub = found?.submenu { level = sub }
                }
                if let found, let action = found.action {
                    entry["chosen"] = path
                    entry["enabled"] = found.isEnabled
                    ok = ok && found.isEnabled
                    if found.isEnabled { asEvent { _ = NSApp.sendAction(action, to: found.target, from: found) } }
                } else {
                    ok = false
                    entry["error"] = "no item \(path)"
                }
            }
            if let want = d["expectSelection"] as? [Int], want.count == 2 {
                let r = tv.selectedRange()
                ok = ok && r.location == want[0] && r.length == want[1]
                entry["selection"] = [r.location, r.length]
            }
            record(entry, ok: ok)
            done()
        }
    }

    /// `{"dividerDrag": 0.35}`: the split view's divider pressed and dragged to that share of the width, released.
    func dividerDragStep(_ to: Double, then done: @escaping () -> Void) {
        guard let wc = clickController, let w = wc.window, !wc.scrollView.isHidden, !wc.previewPane.isHidden else {
            record(["dividerDrag": to, "error": "not in the split layout"], ok: false)
            done()
            return
        }
        let split = wc.splitView
        let x0 = wc.scrollView.frame.maxX + 0.5
        let a = split.convert(NSPoint(x: x0, y: split.bounds.midY), to: nil)
        let b = split.convert(NSPoint(x: split.bounds.width * CGFloat(to), y: split.bounds.midY), to: nil)
        let before = split.ratio
        makeKey(w) { [self] in
            let place = hitPlace(w, a)
            if let e = mouse(.leftMouseDown, a, in: w, count: 1, mods: []) { NSApp.postEvent(e, atStart: false) }
            for i in 1...6 {
                let t = CGFloat(i) / 6
                if let e = mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y), in: w, count: 1, mods: []) { NSApp.postEvent(e, atStart: false) }
            }
            if let e = mouse(.leftMouseUp, b, in: w, count: 1, mods: []) { NSApp.postEvent(e, atStart: false) }
            later(0.4) { [self] in
                let after = split.ratio
                record(["dividerDrag": to, "hitIn": place, "ratio": [Double(before), Double(after)],
                        "saved": wc.session.settings.splitRatio], ok: place == "divider" && abs(Double(after) - to) < 0.03)
                done()
            }
        }
    }
}
#endif
