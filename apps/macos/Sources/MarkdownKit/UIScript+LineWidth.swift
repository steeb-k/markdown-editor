#if DEBUG || UI_SCRIPT
import AppKit

/// The harness's steps for View > Line Width: choosing an item as the menu does (the submenu filled as it is when it opens, the
/// action sent along the responder chain), and asking what the editor's column and the menu's checks say.
extension UIScriptRunner {
    private var lineWidthMenu: NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Line Width" }?.submenu
    }

    /// The preset items of the menu (before the separator) or of "This Document" (after the header).
    private func lineWidthItems(document: Bool) -> [NSMenuItem] {
        guard let menu = lineWidthMenu, let split = menu.items.firstIndex(where: \.isSeparatorItem) else { return [] }
        return document ? Array(menu.items[(split + 2)...]) : Array(menu.items[..<split])
    }

    /// `{"lineWidth": {"choose": "Wide", "scope": "document"}}`: the item of that title in the setting's presets, or in "This
    /// Document" (`scope` is `setting` by default).
    func lineWidthStep(_ s: [String: Any], then done: @escaping () -> Void) {
        let scopeIsDocument = (s["scope"] as? String) == "document"
        guard let title = s["choose"] as? String, let menu = lineWidthMenu else { record(["lineWidth": s, "error": "no menu"], ok: false); done(); return }
        LineWidthMenu.shared.refresh(menu, for: controller)
        guard let item = lineWidthItems(document: scopeIsDocument).first(where: { $0.title == title }), item.isEnabled || item.action != nil,
              let action = item.action else {
            record(["lineWidth": s, "error": "no such item", "items": menu.items.map(\.title)], ok: false)
            done()
            return
        }
        var ok = false
        func send() {
            ok = NSApp.sendAction(action, to: nil, from: item)
            if !ok, let c = controller, c.responds(to: action) { ok = NSApp.sendAction(action, to: c, from: item) }
            if !ok, let d = NSApp.delegate, d.responds(to: action) { ok = NSApp.sendAction(action, to: d, from: item) }
        }
        // Only the document's choice edits the text, and so only it is an undo group: an empty group would take an undo.
        if scopeIsDocument { asEvent(send) } else { send() }
        record(["lineWidth": s], ok: ok)
        done()
    }

    func lineWidthAssertions(_ a: [String: Any]) {
        guard let s = session, let tv = textView, let menu = lineWidthMenu else { check("line width assertions need a window", false); return }
        if let want = a["measure"] as? Int {
            // The text container's width is the column in points: `want` times the body font's "0", as EditorAppearance has it.
            let zero = ("0" as NSString).size(withAttributes: [.font: s.appearance.fonts.body]).width
            let expected = (zero * CGFloat(want)).rounded()
            let got = tv.textContainer?.size.width ?? 0
            check("measure \(want) characters", abs(got - expected) <= 2, "container \(got), expected \(expected)")
        }
        if a["lineWidthMenu"] != nil {
            LineWidthMenu.shared.refresh(menu, for: controller)
            // Validated the way the menu does it, which is where the checks of the presets are set.
            func checked(_ document: Bool) -> [String] {
                let validator = document ? controller as AnyObject? : NSApp.delegate as AnyObject?
                return lineWidthItems(document: document).filter { !$0.isHidden }.compactMap { item in
                    if item.action != nil, item.action != LineWidthMenu.infoAction { _ = (validator as? NSMenuItemValidation)?.validateMenuItem(item) }
                    return item.state == .on ? item.title : nil
                }
            }
            if let m = a["lineWidthMenu"] as? [String: Any] {
                if let want = m["setting"] as? String { check("Line Width checks \(want)", checked(false) == [want], "\(checked(false))") }
                if let want = m["document"] as? String { check("This Document checks \(want)", checked(true) == [want], "\(checked(true))") }
            }
        }
    }
}
#endif
