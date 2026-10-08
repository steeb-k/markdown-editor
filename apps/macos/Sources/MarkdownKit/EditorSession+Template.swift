import AppKit
import MarkdownCore

/// The template a document is shown in (PLAN 3.21): its front matter's `template:` when that names an installed one, else
/// the app's default. The preview, the PDF and print, and the copies all ask here, so they cannot disagree.
extension EditorSession {
    /// The `template:` the front matter names, as the core reads it (after the analysis catches up with the text).
    public func frontMatterTemplateName() -> String? {
        coordinator.sync { $0.frontMatterTemplate() }
    }

    /// The `line_width:` the front matter gives this document (an integer from 30 to 160), as the core reads it.
    public func frontMatterLineWidth() -> Int? {
        coordinator.sync { $0.frontMatterLineWidth() }.map(Int.init)
    }

    /// The template for a front matter name, and the note the Format menu shows when the name is not installed.
    public func resolvedTemplate(frontMatterName: String?) -> (template: InstalledTemplate, note: String?) {
        TemplateStore.shared.resolve(frontMatterName: frontMatterName, defaultName: settings.defaultTemplate)
    }

    /// The preview's stylesheet in the editor's theme and type: the resolved template's.
    public func templateCSS(frontMatterName: String?) -> String {
        let r = resolvedTemplate(frontMatterName: frontMatterName)
        return TemplateStore.shared.css(for: r.template, theme: appearance.theme, typography: PreviewTypography.make(from: appearance))
    }

    /// Makes `name` the front matter's `template:` (nil removes the key) as one undoable edit, "Change Template", keeping the
    /// caret where it was in the text. False when there is nothing to change or the text cannot be edited.
    @discardableResult
    public func setTemplate(name: String?) -> Bool {
        applyFrontMatterEdit(actionName: "Change Template") { $0.setFrontMatterTemplate(name: name) }
    }

    /// Makes `width` the front matter's `line_width:` (nil removes the key) as one undoable edit, "Change Line Width".
    @discardableResult
    public func setLineWidth(_ width: Int?) -> Bool {
        applyFrontMatterEdit(actionName: "Change Line Width") { $0.setFrontMatterLineWidth(width: width.map { UInt32($0) }) }
    }

    /// One front matter edit from the core as one undo step, keeping the caret where it was in the text.
    private func applyFrontMatterEdit(actionName: String, _ make: (Document) -> TextEdit?) -> Bool {
        guard let tv = textView, tv.isEditable else { return false }
        guard var edit = coordinator.sync(make) else { return false }
        // The core's selection is the caret after the new text; the writer's own caret stays with the words it was in.
        let sel = tv.selectedRange()
        let (a, b) = (Int(edit.range.start), Int(edit.range.end))
        let newLength = (edit.replacement as NSString).length
        func moved(_ p: Int) -> Int { p >= b ? p + newLength - (b - a) : (p > a ? a + newLength : p) }
        edit.selection = Utf16Range(start: UInt32(moved(sel.location)), end: UInt32(moved(NSMaxRange(sel))))
        tv.apply(edit, actionName: actionName)
        return true
    }
}

extension TemplateStore {
    /// `page` (a standalone page from the core) with the stylesheet it carries replaced by `css`. The core writes the
    /// Default's; the shell swaps in the template's. Nothing in `css` may end the style element.
    static func replacingStyle(inPage page: String, with css: String) -> String {
        guard let open = page.range(of: "<style>\n"), let close = page.range(of: "</style>\n</head>", range: open.upperBound..<page.endIndex) else { return page }
        let safe = css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
        return String(page[..<open.upperBound]) + safe + "\n" + String(page[close.lowerBound...])
    }
}

/// Format > Template: "Default template", a rule, the installed templates with a check on the effective one, and (when the
/// front matter names one that is not installed) a disabled note. Filled each time the menu opens.
final class DocumentTemplateMenu: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static let shared = DocumentTemplateMenu()

    static let defaultTitle = "Default template"

    static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Template")
        menu.delegate = shared
        fill(menu, for: nil)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let front = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? EditorWindowController
        Self.fill(menu, for: front)
    }

    /// Rebuilds `menu` for the document in `controller` (none: the items are there, none checked).
    static func fill(_ menu: NSMenu, for controller: EditorWindowController?) {
        menu.removeAllItems()
        let session = controller?.session
        let frontMatter = session?.frontMatterTemplateName()
        let resolved = session.map { $0.resolvedTemplate(frontMatterName: frontMatter) }
        // The check follows what the document says: the template it names when installed, else the default item
        // (which is also what a document that names none has).
        let named = (resolved?.note == nil && frontMatter != nil) ? resolved?.template.name : nil

        let action = #selector(EditorWindowController.chooseLookTemplate(_:))
        let standard = menu.addItem(withTitle: defaultTitle, action: action, keyEquivalent: "")
        standard.representedObject = ""
        standard.state = (session != nil && named == nil) ? .on : .off
        menu.addItem(.separator())
        for t in TemplateStore.shared.usable {
            let item = menu.addItem(withTitle: t.name, action: action, keyEquivalent: "")
            item.representedObject = t.name
            item.state = (named.map { TemplateStore.key($0) == TemplateStore.key(t.name) } ?? false) ? .on : .off
        }
        if let note = resolved?.note {
            let missing = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(missing)
        }
    }
}
