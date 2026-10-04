#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore

/// The harness's steps for code highlighting and the language badge. A click goes through the text
/// view's own hit test; the menu it opens is taken by `codeMenuPresenter` (a menu that tracks the mouse
/// never returns inside a script), and the choice is the menu item's own action.
extension UIScriptRunner {
    /// The menu the last badge click opened, and where.
    static var lastCodeMenu: (menu: NSMenu, at: NSPoint)?

    private func hex(_ c: NSColor?) -> String? {
        guard let c = c?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
    }

    /// Every badge in the text (the whole of it is laid out first), in order.
    private func allBadges(ignoringCaret: Bool) -> [CodeBadge] {
        guard let lm = textView?.layoutManager as? EditorLayoutManager, let storage = session?.storage else { return [] }
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage.length))
        return lm.codeBadges(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs), ignoringCaret: ignoringCaret)
    }

    /// The badge of the block holding `needle`, wherever the caret is.
    func badge(of needle: String, ignoringCaret: Bool = false) -> CodeBadge? {
        guard let tv = textView, let lm = tv.layoutManager as? EditorLayoutManager, let storage = session?.storage else { return nil }
        let r = (storage.string as NSString).range(of: needle)
        guard r.location != NSNotFound else { return nil }
        let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: 1), actualCharacterRange: nil)
        return lm.codeBadges(forGlyphRange: g, ignoringCaret: ignoringCaret).first { $0.block.location <= r.location && r.location <= NSMaxRange($0.block) }
    }

    /// `{"codeBadge": {"click": "needle", "choose": "Python"}}`: clicks the badge of the block holding the text
    /// and, when `choose` is there, picks that language in the menu it opened (a title, or a token). `menuOnly` opens the menu only.
    func codeBadgeStep(_ c: [String: Any]) {
        guard let tv = textView, let needle = c["click"] as? String else {
            record(["codeBadge": c, "error": "no text view or no `click`"], ok: false)
            return
        }
        Self.lastCodeMenu = nil
        tv.codeMenuPresenter = { menu, at in Self.lastCodeMenu = (menu, at) }
        guard let b = badge(of: needle) else {
            record(["codeBadge": needle, "error": "no badge there (none for the block, or the caret hides it)"], ok: false)
            return
        }
        let o = tv.textContainerOrigin
        let hit = tv.handleBadgeClick(at: NSPoint(x: b.frame.midX + o.x, y: b.frame.midY + o.y))
        var entry: [String: Any] = ["codeBadge": needle, "text": b.text, "clicked": hit, "menuOpened": Self.lastCodeMenu != nil]
        var ok = hit && Self.lastCodeMenu != nil
        if let choose = c["choose"] as? String, let menu = Self.lastCodeMenu?.menu {
            func find(_ m: NSMenu) -> NSMenuItem? {
                for i in m.items {
                    if i.action != nil, i.title == choose || (i.representedObject as? String) == choose { return i }
                    if let s = i.submenu, let f = find(s) { return f }
                }
                return nil
            }
            if let item = find(menu), let target = item.target as? NSObject, let action = item.action {
                // As an event: one undo group, so undo and the document's edited state are real.
                asEvent { _ = target.perform(action, with: item) }
                entry["chose"] = item.title
            } else {
                entry["error"] = "no menu item \(choose)"
                ok = false
            }
        }
        record(entry, ok: ok)
    }

    /// `{"codeBadge": {"click": "needle", "real": true, "choose": "Python", "keys": ["down", "return"]}}`: a real click on
    /// the badge (mouse events posted to the app's queue, through the window's hit-testing and the text view's `mouseDown`),
    /// so the menu really pops up and tracks; once it is open it is dismissed through its own API (`cancelTracking`) and
    /// `choose` is then taken through the item's action, or `keys` are posted to the open menu as key events (arrows,
    /// `return`, `escape`: the menu's own keyboard navigation). Logs where the menu opened against the badge, whether the
    /// caret stayed and what the text became.
    func codeBadgeRealStep(_ c: [String: Any], then done: @escaping () -> Void) {
        guard let tv = textView, let w = tv.window, let needle = c["click"] as? String else {
            record(["codeBadge": c, "error": "no text view or no `click`"], ok: false)
            done()
            return
        }
        tv.codeMenuPresenter = nil
        Self.lastCodeMenu = nil
        guard let b = badge(of: needle) else {
            record(["codeBadge": needle, "real": true, "error": "no badge there (none for the block, or the caret hides it)"], ok: false)
            done()
            return
        }
        let frame = tv.viewFrame(of: b)
        let selBefore = tv.selectedRange()
        makeKey(w) { [self] in
            let p = tv.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            let place = hitPlace(w, p)
            var opened: NSMenu?
            var closed = false
            let nc = NotificationCenter.default
            let begin = nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                MainActor.assumeIsolated {
                    if opened == nil, let m = n.object as? NSMenu, m.title == "Language" { opened = m }
                }
            }
            let end = nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { n in
                MainActor.assumeIsolated { if let m = n.object as? NSMenu, m === opened { closed = true } }
            }
            func post(_ type: NSEvent.EventType) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) { NSApp.postEvent(e, atStart: false) }
            }
            post(.leftMouseDown)
            post(.leftMouseUp)
            let keys = c["keys"] as? [String] ?? []
            waitFor(3, { opened != nil }) { [self] isOpen in
                guard isOpen, let menu = opened else {
                    nc.removeObserver(begin); nc.removeObserver(end)
                    record(["codeBadge": needle, "real": true, "hitIn": place, "active": NSApp.isActive, "key": w.isKeyWindow,
                            "error": "no menu opened"], ok: false)
                    done()
                    return
                }
                Self.lastCodeMenu = (menu, NSPoint(x: frame.minX, y: frame.maxY + 2))
                let checked = menu.items.filter { $0.state == .on }.map(\.title)
                // Give the menu a moment on screen, then close it: by keys, or through its own API.
                var highlights: [String] = []
                // Keys one at a time, the highlighted item noted after each (the menu answers each in its own turn).
                func press(_ rest: ArraySlice<String>, then next: @escaping () -> Void) {
                    guard let k = rest.first else { next(); return }
                    let (chars, code, mods): (String, UInt16, NSEvent.ModifierFlags) = switch k {
                    case "down": ("\u{F701}", 125, [.function, .numericPad])
                    case "up": ("\u{F700}", 126, [.function, .numericPad])
                    case "right": ("\u{F703}", 124, [.function, .numericPad])
                    case "left": ("\u{F702}", 123, [.function, .numericPad])
                    case "escape": ("\u{1B}", 53, [])
                    default: ("\r", 36, [])
                    }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    later(0.15) {
                        highlights.append(menu.highlightedItem?.title ?? "-")
                        press(rest.dropFirst(), then: next)
                    }
                }
                // Give the menu a moment on screen, then close it: by keys, or through its own API.
                later(0.3) { [self] in
                    if keys.isEmpty { menu.cancelTracking() }
                    press(keys[...]) { [self] in
                    waitFor(3, { closed }) { [self] didClose in
                        nc.removeObserver(begin); nc.removeObserver(end)
                        if !didClose { menu.cancelTrackingWithoutAnimation() }
                        var entry: [String: Any] = ["codeBadge": needle, "real": true, "hitIn": place, "menuOpened": true, "menuClosed": didClose,
                                                    "checked": checked, "active": NSApp.isActive, "key": w.isKeyWindow, "highlighted": highlights]
                        var ok = didClose && place == "text"
                        if let want = c["expectHighlighted"] as? [String] { ok = ok && Array(highlights.prefix(want.count)) == want }
                        if let choose = c["choose"] as? String, keys.isEmpty {
                            func find(_ m: NSMenu) -> NSMenuItem? {
                                for i in m.items {
                                    if i.action != nil, i.title == choose || (i.representedObject as? String) == choose { return i }
                                    if let s = i.submenu, let f = find(s) { return f }
                                }
                                return nil
                            }
                            if let item = find(menu), let owner = item.menu {
                                asEvent { owner.performActionForItem(at: owner.index(of: item)) }
                                entry["chose"] = item.title
                            } else {
                                entry["error"] = "no menu item \(choose)"
                                ok = false
                            }
                        }
                        later(0.3) { [self] in
                            let sel = tv.selectedRange()
                            entry["selection"] = [sel.location, sel.length]
                            if c["choose"] == nil, keys.isEmpty {
                                // Nothing chosen: the click went no further than the badge (the caret stayed).
                                ok = ok && sel == selBefore
                            }
                            record(entry, ok: ok)
                            done()
                        }
                    }
                    }
                }
            }
        }
    }

    func codeAssertions(_ a: [String: Any]) {
        guard let tv = textView, let s = session else { check("code assertions need an editor", false); return }
        let p = s.appearance.palette
        if let want = a["badges"] as? [String] {
            let got = allBadges(ignoringCaret: false).map(\.text)
            check("code badges \(want)", got == want, "\(got)")
        }
        if let want = a["badgesIgnoringCaret"] as? [String] {
            let got = allBadges(ignoringCaret: true).map(\.text)
            check("code badges (caret ignored) \(want)", got == want, "\(got)")
        }
        if let want = a["badgesInView"] as? [String] {
            let got = tv.visibleCodeBadges().map(\.text)
            check("code badges in view \(want)", got == want, "\(got)")
        }
        if let n = a["badgeAtTopRightOf"] as? String {
            if let b = badge(of: n, ignoringCaret: true), let lm = tv.layoutManager as? EditorLayoutManager,
               let panel = lm.blockPanels(forGlyphRange: lm.glyphRange(forCharacterRange: b.block, actualCharacterRange: nil)).first(where: { $0.run.location == b.block.location }) {
                let dx = panel.rect.maxX - EditorLayoutManager.badgeMargin.width - b.frame.maxX
                let dy = b.frame.minY - (panel.rect.minY + EditorLayoutManager.badgeMargin.height)
                check("badge of \(n.debugDescription) at the panel's top right", abs(dx) <= 1 && abs(dy) <= 1 && panel.rect.contains(b.frame), "dx \(dx) dy \(dy) panel \(panel.rect) badge \(b.frame)")
            } else {
                check("badge of \(n.debugDescription) at the panel's top right", false, "no badge")
            }
        }
        if let n = a["badgeHiddenByCaret"] as? String {
            let all = badge(of: n, ignoringCaret: true) != nil, shown = badge(of: n) != nil
            check("badge of \(n.debugDescription) hidden by the caret", all && !shown, "exists \(all) shown \(shown)")
        }
        if let fences = a["fenceHidden"] as? [String], let lm = tv.layoutManager as? EditorLayoutManager {
            // The text at the start of each needle is concealed (Live mode, caret elsewhere).
            let bad = fences.filter { f in
                let r = (s.text as NSString).range(of: f)
                return r.location == NSNotFound || !lm.live.isHidden(r.location)
            }
            check("fences concealed \(fences)", bad.isEmpty, "not concealed: \(bad)")
        }
        if let n = a["noBadge"] as? String {
            check("no badge for \(n.debugDescription)", badge(of: n, ignoringCaret: true) == nil)
        }
        if let n = a["caretClearOfBadge"] as? Bool, n, let lm = tv.layoutManager as? EditorLayoutManager {
            // Wherever the caret is, the insertion point is not under a badge that is showing.
            let sel = tv.selectedRange()
            let g = lm.glyphRange(forCharacterRange: NSRange(location: min(sel.location, max(0, s.storage.length - 1)), length: 1), actualCharacterRange: nil)
            let line = lm.lineFragmentUsedRect(forGlyphAt: g.location, effectiveRange: nil)
            let x = lm.location(forGlyphAt: g.location).x + lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil).minX
            let hit = tv.visibleCodeBadges().contains { $0.frame.minY <= line.maxY && line.minY <= $0.frame.maxY && x >= $0.frame.minX - 1 && x <= $0.frame.maxX + 1 }
            check("the caret is not under a badge", sel.length != 0 || !hit, "x \(x)")
        }
        if let colours = a["codeColours"] as? [[String: Any]] {
            for c in colours {
                guard let needle = c["needle"] as? String, let role = c["role"] as? String else { continue }
                let r = (s.text as NSString).range(of: needle)
                guard r.location != NSNotFound else { check("code colour of \(needle.debugDescription)", false, "not in the text"); continue }
                let at = r.location + (c["offset"] as? Int ?? 0)
                // What is drawn: the overlay's colour (the roles are its lowest layer) over the stored one. Text outside
                // the window the overlay paints (a 1 MB document is painted around what is visible) is asked of the
                // layer instead: what scrolling there would draw.
                s.overlay.apply()
                var shown = s.layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) as? NSColor
                if !NSLocationInRange(at, s.overlay.appliedWindow), let run = s.overlay.layers.code.first(where: { NSLocationInRange(at, $0.range) }) {
                    shown = s.overlay.color(for: run.paint)
                }
                let got = hex(shown ?? s.storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)
                let sx = p.syntax
                let want: NSColor? = [
                    "comment": sx.comment, "keyword": sx.keyword, "string": sx.string, "number": sx.number, "function": sx.function,
                    "type": sx.type, "tag": sx.tag, "variable": sx.variable, "code": p.codeText, "text": p.text, "markup": p.markup,
                    "focusDim": p.focusDim,
                ][role]
                check("code colour of \(needle.debugDescription) is \(role)", got != nil && got == hex(want), "\(got ?? "nil") wanted \(hex(want) ?? "?")")
            }
        }
        if let n = a["temporaryColour"] as? [String: Any], let needle = n["needle"] as? String {
            let r = (s.text as NSString).range(of: needle)
            let t = hex(s.layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: r.location, effectiveRange: nil) as? NSColor)
            // `none`: nothing (the stored colour shows); `focusDim`; or a role (the overlay's colour for code).
            let sx = p.syntax
            let roles: [String: NSColor] = ["comment": sx.comment, "keyword": sx.keyword, "string": sx.string, "number": sx.number, "function": sx.function,
                                            "type": sx.type, "tag": sx.tag, "variable": sx.variable]
            let want = n["is"] as? String == "focusDim" ? hex(p.focusDim) : (n["is"] as? String).flatMap { roles[$0] }.flatMap { hex($0) }
            check("temporary colour of \(needle.debugDescription) is \(n["is"] as? String ?? "none")", t == want, "\(t ?? "none")")
        }
        if let m = a["codeMenu"] as? [String: Any] {
            guard let menu = Self.lastCodeMenu?.menu else { check("a language menu is open", false); return }
            if let first = m["first"] as? String { check("menu starts with \(first)", menu.items.first?.title == first, "\(menu.items.first?.title ?? "")") }
            if let checked = m["checked"] as? String {
                let on = menu.items.filter { $0.state == .on }.map(\.title)
                check("menu checks \(checked)", on == [checked], "\(on)")
            }
            if let n = m["commonCount"] as? Int {
                let at = menu.items.firstIndex { $0.isSeparatorItem }
                check("menu has \(n) common languages", at == n, "\(String(describing: at))")
            }
            if let last = m["last"] as? String { check("menu ends with \(last)", menu.items.last?.title == last, "\(menu.items.last?.title ?? "")") }
            if let groups = m["allGroups"] as? Int {
                let got = menu.items.last?.submenu?.items.count
                check("All has \(groups) letter groups", got == groups, "\(String(describing: got))")
            }
        }
        if let n = a["accessibleBadges"] as? [String] {
            // One button per badge in view.
            let got = (tv.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }.filter { $0.hasPrefix("Language:") }
            let inView = tv.visibleCodeBadges(ignoringCaret: true).map { "Language: \($0.text)" }
            check("accessible badges \(n)", n.allSatisfy(got.contains) && got == inView, "\(got) in view \(inView)")
        }
        if let press = a["pressAccessibleBadge"] as? String {
            Self.lastCodeMenu = nil
            tv.codeMenuPresenter = { menu, at in Self.lastCodeMenu = (menu, at) }
            let el = (tv.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == press }
            let pressed = el?.accessibilityPerformPress() ?? false
            check("press \(press.debugDescription)", pressed && Self.lastCodeMenu != nil, "pressed \(pressed)")
        }
    }
}
#endif
