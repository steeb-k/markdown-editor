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

// MARK: the Templates window

/// The harness's steps for the Templates window (`{"templates": {...}}`, one action per step, see `scripts/macos/ui/templates.json`)
/// and what it asserts about it. The model is driven through the same calls the window's buttons and fields make; the click on
/// the sample is a real mouse event on the page.
extension UIScriptRunner {
    private var templatesController: TemplatesWindowController { TemplatesWindowController.shared }
    private var templateEditor: TemplateEditor { templatesController.editor }

    func templatesStep(_ t: [String: Any], then done: @escaping () -> Void) {
        let editor = templateEditor
        var entry = t
        var ok = true
        if let name = t["select"] as? String { ok = editor.select(named: name) && ok }
        if t["new"] as? Bool == true { editor.newTemplate() }
        if t["duplicate"] as? Bool == true { editor.duplicateSelected() }
        if let name = t["rename"] as? String { editor.rename(to: name) }
        if let key = t["element"] as? String {
            editor.selectTarget(key)
            ok = ok && editor.targetKey == key
        }
        if let values = t["set"] as? [String: Any] {
            // `expectRejected`: the change is meant to be refused (a built-in template is read-only).
            let problem = setFields(values)
            if t["expectRejected"] as? Bool == true { ok = ok && problem != nil } else if let problem { entry["error"] = problem; ok = false }
        }
        if let appearance = t["appearance"] as? String { editor.setSampleDark(appearance == "dark") }
        if t["undo"] as? Bool == true || t["redo"] as? Bool == true {
            // Through the responder chain, as Edit > Undo does it: the window must be key, and the action finds its manager.
            let redo = t["redo"] as? Bool == true
            guard let w = templatesController.window else { record(["templates": entry, "error": "no window"], ok: false); done(); return }
            makeKey(w) {
                let before = editor.undoManager.canUndo
                let sent = NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
                entry["canUndoBefore"] = before
                self.record(["templates": entry], ok: sent)
                done()
            }
            return
        }
        if t["delete"] as? Bool == true {
            let name = editor.working?.name ?? ""
            templatesController.confirmDelete()
            guard let w = templatesController.window else { record(["templates": entry, "error": "no window"], ok: false); done(); return }
            // The confirmation is a sheet on the window: Delete is its first button.
            waitFor(3, { w.attachedSheet != nil }) { found in
                guard found, let sheet = w.attachedSheet else {
                    self.record(["templates": entry, "error": "no confirmation sheet"], ok: false)
                    done()
                    return
                }
                entry["sheet"] = (sheet.contentView?.subviews ?? []).compactMap { ($0 as? NSTextField)?.stringValue }.first ?? ""
                w.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                self.waitFor(3, { !editor.templates.contains { $0.name == name && !$0.isBuiltIn } }) { gone in
                    self.record(["templates": entry], ok: ok && gone)
                    done()
                }
            }
            return
        }
        if let key = t["clickSample"] as? String {
            clickSample(key, entry, then: done)
            return
        }
        if let answer = t["answerUpdate"] as? String {
            answerUpdate(answer, entry, then: done)
            return
        }
        if let name = t["renameInline"] as? String {
            renameInline(name, t, then: done)
            return
        }
        // Import and Export as their panels' completions do it (the panels themselves are the system's, out of process).
        // A path starting `out:` is in the output folder.
        func url(_ path: String) -> URL { path.hasPrefix("out:") ? outDir.appendingPathComponent(String(path.dropFirst(4))) : resolve(path) }
        if let path = t["import"] as? String {
            let count = editor.templates.count
            editor.importTemplate(at: url(path))
            entry["selected"] = editor.working?.name ?? ""
            if let problem = editor.problem { entry["problem"] = problem; editor.problem = nil }
            ok = ok && editor.templates.count == count + 1 && entry["problem"] == nil
        }
        if let path = t["export"] as? String {
            let destination = url(path)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            editor.export(to: destination, zipped: t["zipped"] as? Bool == true)
            if let problem = editor.problem { entry["problem"] = problem; editor.problem = nil }
            ok = ok && entry["problem"] == nil && FileManager.default.fileExists(atPath: destination.path)
        }
        // (A change of template or of a field reaches the page by the run loop: given a turn before the next step.)
        templatesController.sample.waitUntilSettled()
        record(["templates": entry], ok: ok)
        done()
    }

    /// Sets fields of the shown element (or the page) as `template.toml` spells them, through the core's own parser: a
    /// value the file would reject is rejected here too. `null` clears a field. Nil when all went in, else why not.
    private func setFields(_ values: [String: Any]) -> String? {
        let editor = templateEditor
        guard !editor.isReadOnly else { return "the selected template is built in" }
        let section = editor.isPage ? "page" : "elements.\(editor.targetKey)"
        var lines = ["[\(section)]"]
        var cleared: [String] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            if value is NSNull { cleared.append(key); continue }
            guard let literal = Self.tomlLiteral(value, key: key) else { return "cannot write \(key)" }
            lines.append("\(key) = \(literal)")
        }
        let parsed: Template
        do { parsed = try parseTemplate(toml: lines.joined(separator: "\n") + "\n") } catch { return "\(error)" }
        // In key order: each field is an undo step of its own, and a script's undo assertions need the steps in an
        // order that does not change from one process to the next (a dictionary's does).
        for key in cleared + values.keys.filter({ !(values[$0] is NSNull) }).sorted() {
            let clearing = cleared.contains(key)
            if editor.isPage {
                guard let field = TemplatePageField(rawValue: key) else { return "no page field \(key)" }
                editor.change(key: "script.page.\(key)", actionName: "Change \(key)") { t in
                    field.copy(from: clearing ? TemplatePage() : parsed.spec.page, to: &t.spec.page)
                }
            } else {
                guard let kind = editor.targetKind, let field = TemplateField(rawValue: key) else { return "no field \(key)" }
                let source = clearing ? TemplateElementStyle() : (parsed.spec.elements.first { $0.kind == kind }?.style ?? TemplateElementStyle())
                editor.change(key: "script.\(kind).\(key)", actionName: "Change \(field.title)") { t in
                    TemplateEditor.update(&t.spec, kind) { field.copy(from: source, to: &$0) }
                }
            }
        }
        return nil
    }

    /// A JSON value as `template.toml` writes it: strings quoted, numbers and booleans bare, an object as an inline table.
    static func tomlLiteral(_ value: Any, key: String = "") -> String? {
        if let s = value as? String { return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            // The floats of the file (`line_height`, `measure_ch`) always have a point, as the core writes them.
            if ["line_height", "measure_ch"].contains(key) {
                let d = n.doubleValue
                return d == d.rounded() ? String(format: "%.1f", d) : "\(d)"
            }
            return "\(n)"
        }
        if let d = value as? [String: Any] {
            let parts = d.sorted { $0.key < $1.key }.compactMap { k, v in tomlLiteral(v, key: k).map { "\(k) = \($0)" } }
            return "{ " + parts.joined(separator: ", ") + " }"
        }
        return nil
    }

    /// The right-hand side of `key` in `[section]` of a `template.toml` text.
    static func tomlValue(_ toml: String, section: String, key: String) -> String? {
        var inside = false
        for line in toml.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { inside = l == "[\(section)]"; continue }
            if inside, l.hasPrefix(key + " = ") { return String(l.dropFirst(key.count + 3)) }
        }
        return nil
    }

    /// A real click (mouse down and up, posted to the app) at the middle of the first element of a kind on the sample page.
    private func clickSample(_ key: String, _ entry: [String: Any], then done: @escaping () -> Void) {
        var entry = entry
        let editor = templateEditor
        guard let w = templatesController.window, let selector = editor.selector(forKey: key),
              let p = templatesController.sample.windowPoint(ofSelector: selector) else {
            record(["templates": entry, "error": "no such element on the sample"], ok: false)
            done()
            return
        }
        let sample = templatesController.sample
        makeKey(w) {
            entry["at"] = NSStringFromPoint(p)
            let clicksBefore = sample.clicks.count
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            self.waitFor(3, { sample.clicks.count > clicksBefore }) { reported in
                entry["reported"] = sample.clicks.last ?? ""
                entry["key"] = w.isKeyWindow
                self.record(["templates": entry], ok: reported)
                done()
            }
        }
    }

    /// The sheet a rename asks on the Templates window ("Update N documents that use ..."), answered through its buttons:
    /// `update` presses Update Documents, `leave` Leave, `none` checks that nothing is asked. `expect` is the question it
    /// must read. After Update the step waits for the documents to be written (the sheet's completion is what writes).
    private func answerUpdate(_ answer: String, _ entry: [String: Any], then done: @escaping () -> Void) {
        var entry = entry
        guard let w = templatesController.window else { record(["templates": entry, "error": "no window"], ok: false); done(); return }
        if answer == "none" {
            waitFor(1, { w.attachedSheet != nil }) { found in
                self.record(["templates": entry], ok: !found)
                done()
            }
            return
        }
        waitFor(5, { w.attachedSheet != nil }) { found in
            guard found, let sheet = w.attachedSheet else {
                self.record(["templates": entry, "error": "no question sheet"], ok: false)
                done()
                return
            }
            func all<V: NSView>(_ type: V.Type, in view: NSView?) -> [V] {
                guard let view else { return [] }
                // `??` binds looser than `+`: without the parentheses a matching view hides what is inside it.
                return ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
            }
            let texts = all(NSTextField.self, in: sheet.contentView).map(\.stringValue).filter { !$0.isEmpty }
            entry["sheet"] = texts
            let wanted = answer == "update" ? "Update Documents" : "Leave"
            let button = all(NSButton.self, in: sheet.contentView).first { $0.title == wanted }
            var ok = button != nil
            if let want = entry["expect"] as? String { ok = ok && texts.first == want }
            button?.performClick(nil)
            // The sheet ends, and the edits are written off the main thread: a moment for them before the next step.
            self.waitFor(5, { w.attachedSheet == nil }) { closed in
                later(answer == "update" ? 0.8 : 0.2) {
                    self.record(["templates": entry], ok: ok && closed)
                    done()
                }
            }
        }
    }

    /// The sidebar's rename in place, as a person does it: a real double-click (posted mouse events) on the selected
    /// template's row, the text in the field that comes up replaced by `name` typed as key events, then Return (or
    /// `"end": "escape"`, which keeps the old name). `expect` is the name the template must have afterwards (the typed one
    /// by default; a clash is made unique, an empty name changes nothing).
    private func renameInline(_ name: String, _ t: [String: Any], then done: @escaping () -> Void) {
        var entry = t
        let editor = templateEditor
        guard let w = templatesController.window, let current = editor.working,
              let table = Self.firstTable(in: w.contentView) else {
            record(["templates": entry, "error": "no window, template or list"], ok: false)
            done()
            return
        }
        // The list's rows: the "Built in" header, the built-in ones, the "Yours" header, yours.
        let rows = [nil] + editor.builtIn.map(\.id) + [nil] + editor.yours.map(\.id)
        entry["rows"] = table.numberOfRows
        guard table.numberOfRows == rows.count, let row = rows.firstIndex(of: current.id) else {
            record(["templates": entry, "error": "the list does not have the expected rows"], ok: false)
            done()
            return
        }
        let r = table.rect(ofRow: row)
        let p = table.convert(NSPoint(x: r.minX + min(60, r.width / 2), y: r.midY), to: nil)
        let before = current.name
        let expected = t["expect"] as? String ?? name
        let escape = t["end"] as? String == "escape"
        makeKey(w) {
            for count in [1, 2] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                                  pressure: type == .leftMouseUp ? 0 : 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
            }
            // The field takes the keyboard (its field editor is the window's first responder).
            self.waitFor(3, { (w.firstResponder as? NSTextView)?.isFieldEditor == true }) { editing in
                entry["fieldEditing"] = editing
                guard editing, let fieldEditor = w.firstResponder as? NSTextView else {
                    // What the double-click met, for the log.
                    entry["responder"] = w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    entry["hit"] = w.contentView?.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil"
                    self.record(["templates": entry, "error": "no field came up for the name"], ok: false)
                    done()
                    return
                }
                entry["fieldText"] = fieldEditor.string
                fieldEditor.selectAll(nil)
                func key(_ chars: String, _ code: UInt16) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                    isARepeat: false, keyCode: code) {
                            w.sendEvent(e)
                        }
                    }
                }
                if name.isEmpty { key("\u{7F}", 51) }
                for c in name { key(String(c), c == " " ? 49 : 0) }
                if escape { key("\u{1B}", 53) } else { key("\r", 36) }
                let want = escape ? before : expected
                // The field editor resigns a render pass before the row takes its text field down; a double-click posted
                // in between lands on the field, not the row, so the step ends once the field is gone too.
                func fieldShown() -> Bool { Self.editableFields(in: table).contains { $0.window != nil } }
                self.waitFor(3, { editor.working?.name == want && (w.firstResponder as? NSTextView)?.isFieldEditor != true && !fieldShown() }) { renamed in
                    entry["name"] = editor.working?.name ?? ""
                    entry["onDisk"] = editor.working.map { TemplateStore.readPackage($0.url, builtIn: false)?.name ?? "missing" } ?? "none"
                    self.record(["templates": entry], ok: renamed && entry["onDisk"] as? String == want)
                    done()
                }
            }
        }
    }

    /// The text fields a row's inline rename puts up (a row's label is not one).
    nonisolated private static func editableFields(in view: NSView) -> [NSTextField] {
        let own: [NSTextField] = (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []
        return own + view.subviews.flatMap(editableFields)
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = firstTable(in: sub) { return t } }
        return nil
    }

    func templatesAssertions(_ t: [String: Any]) {
        let editor = templateEditor
        let sample = templatesController.sample
        let toml = editor.working.map { templateToml(template: $0.template) } ?? ""
        let section = editor.isPage ? "page" : "elements.\(editor.targetKey)"
        if let want = t["selected"] as? String { check("templates selected \(want)", editor.working?.name == want, editor.working?.name ?? "none") }
        if let want = t["element"] as? String { check("templates element \(want)", editor.targetKey == want, editor.targetKey) }
        if let want = t["list"] as? [String] { check("templates list \(want)", editor.templates.map(\.name) == want, "\(editor.templates.map(\.name))") }
        if let want = t["defaultTemplate"] as? String { check("default template \(want)", Settings.shared.defaultTemplate == want, Settings.shared.defaultTemplate) }
        if let want = t["readOnly"] as? Bool { check("templates read-only \(want)", editor.isReadOnly == want) }
        if let want = t["theme"] as? String { check("templates sample theme \(want)", editor.sampleTheme.id == want, editor.sampleTheme.id) }
        if let want = t["outline"] as? String { let got = sample.pageOutline(); check("templates outline \(want)", got == want, got ?? "none") }
        if let want = t["customCSS"] as? Bool { check("templates custom css \(want)", editor.working?.hasCustomCSS == want) }
        if let want = t["canUndo"] as? Bool { check("templates can undo \(want)", editor.undoManager.canUndo == want) }
        if let want = t["lastClick"] as? String { check("templates last click \(want)", sample.clicks.last == want, sample.clicks.last ?? "none") }
        for (name, wantContains) in [("sampleStyleContains", true), ("sampleStyleLacks", false)] {
            let wanted = (t[name] as? [String]) ?? (t[name] as? String).map { [$0] } ?? []
            guard !wanted.isEmpty else { continue }
            let css = sample.pageStyle()
            for text in wanted { check("templates sample style \(wantContains ? "contains" : "lacks") \(text.debugDescription)", css.contains(text) == wantContains) }
        }
        if let fields = t["field"] as? [String: Any] {
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                let got = Self.tomlValue(toml, section: section, key: key)
                let want = value is NSNull ? nil : Self.tomlLiteral(value, key: key)
                check("templates field \(key) = \(want ?? "unset")", got == want, got ?? "unset")
            }
        }
        if let fields = t["saved"] as? [String: Any] {
            // What is on disk, read again: the package as another program (or the next launch) finds it.
            let disk = editor.working.flatMap { TemplateStore.readPackage($0.url, builtIn: false) }.map { templateToml(template: $0.template) } ?? ""
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                let got = Self.tomlValue(disk, section: section, key: key)
                let want = value is NSNull ? nil : Self.tomlLiteral(value, key: key)
                check("templates saved \(key) = \(want ?? "unset")", got == want, got ?? "unset")
            }
        }
    }
}
#endif
