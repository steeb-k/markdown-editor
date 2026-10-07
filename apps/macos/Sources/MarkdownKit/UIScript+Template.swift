#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore

/// The harness's steps for Format > Template: choosing an item as the menu does (so the menu's own items, checks and action
/// are what is tested), and asking what the document's template and the menu say.
extension UIScriptRunner {
    /// Format > Template as it stands when it opens for this window.
    private func filledTemplateMenu() -> NSMenu? {
        guard let c = controller,
              let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Format" })?.submenu?.items.first(where: { $0.title == "Template" })?.submenu
        else { return nil }
        DocumentTemplateMenu.fill(menu, for: c)
        return menu
    }

    /// Chooses the item named `name` ("" is "Default template") from Format > Template.
    func templateStep(_ name: String, then done: @escaping () -> Void) {
        guard let menu = filledTemplateMenu(), let c = controller else { record(["template": name, "error": "no menu"], ok: false); done(); return }
        let item = menu.items.first { ($0.representedObject as? String).map { TemplateStore.key($0) == TemplateStore.key(name) } ?? false }
        guard let item, item.isEnabled, let action = item.action else {
            record(["template": name, "error": "no such item", "items": menu.items.map(\.title)], ok: false)
            done()
            return
        }
        var ok = false
        asEvent {
            ok = NSApp.sendAction(action, to: nil, from: item)
            if !ok, c.responds(to: action) { ok = NSApp.sendAction(action, to: c, from: item) }
        }
        record(["template": name], ok: ok)
        done()
    }

    func templateAssertions(_ t: [String: Any]) {
        guard let s = session, let c = controller else { check("template assertions need a window", false); return }
        let frontMatter = s.frontMatterTemplateName()
        let resolved = s.resolvedTemplate(frontMatterName: frontMatter)
        if let want = t["effective"] as? String {
            check("template effective \(want)", TemplateStore.key(resolved.template.name) == TemplateStore.key(want), resolved.template.name)
        }
        if let want = t["frontMatter"] as? String {
            check("template in the front matter \(want.debugDescription)", (frontMatter ?? "") == want, frontMatter ?? "none")
        }
        if let want = t["previewUses"] as? String {
            // What the page was last styled with, and that its stylesheet is that template's.
            let p = c.previewController
            _ = p.waitUntilSettled(timeout: 20)
            let got = p.appliedTemplate.map { url in TemplateStore.shared.templates.first(where: { $0.url == url })?.name ?? "?" } ?? "none"
            check("preview styled by template \(want)", TemplateStore.key(got) == TemplateStore.key(want), got)
        }
        if t["menuChecked"] != nil || t["menuHas"] != nil || t["menuLacks"] != nil {
            let titles: [String]
            var checked: [String] = []
            if let menu = filledTemplateMenu() {
                titles = menu.items.map(\.title)
                checked = menu.items.filter { $0.state == .on }.map(\.title)
            } else { titles = [] }
            if let want = t["menuChecked"] as? String { check("template menu checks \(want)", checked == [want], "\(checked)") }
            for want in (t["menuHas"] as? [String]) ?? [] { check("template menu has \(want.debugDescription)", titles.contains(want), "\(titles)") }
            for want in (t["menuLacks"] as? [String]) ?? [] { check("template menu lacks \(want.debugDescription)", !titles.contains(want), "\(titles)") }
        }
    }
}
#endif
