#if DEBUG || UI_SCRIPT
import AppKit

// MARK: the Settings window

/// The harness's steps for the Settings window (`{"settings": {"pane": "Editor"}}`, `{"settings": {"search": "spell"}}`,
/// `{"settings": {"flip": 0}}`, see `scripts/macos/ui/settings.json`) and what it asserts about it. A search is typed into
/// the sidebar's search field as key events through the window, and the result is read from the model, so the field, the
/// binding and the filtering are all in the loop.
extension UIScriptRunner {
    private var settingsController: SettingsWindowController { SettingsWindowController.shared }

    func settingsStep(_ t: [String: Any], then done: @escaping () -> Void) {
        let controller = settingsController
        let model = controller.model
        var entry = t
        guard let w = controller.window, w.isVisible else {
            record(["settings": entry, "error": "the Settings window is not shown"], ok: false)
            done()
            return
        }
        if let name = t["pane"] as? String {
            guard let pane = SettingsPane(rawValue: name) else {
                record(["settings": entry, "error": "no such pane"], ok: false)
                done()
                return
            }
            model.pane = pane
        }
        if let index = (t["flip"] as? NSNumber)?.intValue {
            // The i-th switch of the shown pane, pressed as a click on it would.
            let found = settingsControls()
            guard found.indices.contains(index) else {
                record(["settings": entry, "error": "no switch \(index) among \(found.count)"], ok: false)
                done()
                return
            }
            found[index].performClick(nil)
        }
        if let keys = t["keys"] as? [String] {
            // Keys pressed with the Settings window key, as the window server would deliver them: Command keys go to the
            // window's key equivalents and then to the main menu, the others to the window.
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            for name in keys { settingsKey(name, in: w) }
        }
        if t["clearButton"] as? Bool == true, let field = controller.searchField,
           let button = (field.cell as? NSSearchFieldCell)?.cancelButtonCell, let action = button.action {
            // The field's own clear button, sending what a click on it sends.
            NSApp.sendAction(action, to: button.target ?? field, from: field)
        }
        guard let text = t["search"] as? String else {
            // Let SwiftUI draw the pane before the next step looks at it.
            later(0.2) { self.record(["settings": entry], ok: true); done() }
            return
        }
        controller.focusSearch()
        waitFor(3, { (w.firstResponder as? NSTextView)?.isFieldEditor == true && controller.searchField != nil }) { editing in
            guard editing, let editor = w.firstResponder as? NSTextView else {
                entry["error"] = "the search field did not take the keyboard"
                self.record(["settings": entry], ok: false)
                done()
                return
            }
            func key(_ chars: String, _ code: UInt16) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: code) {
                        w.sendEvent(e)
                    }
                }
            }
            // What was typed before is replaced: select it all, then Delete or the new characters over it.
            editor.selectAll(nil)
            if text.isEmpty { key("\u{7F}", 51) }
            for c in text { key(String(c), c == " " ? 49 : 0) }
            self.waitFor(3, { model.query == text }) { typed in
                entry["query"] = model.query
                // The panes and rows follow in the next render pass.
                later(0.3) { self.record(["settings": entry], ok: typed); done() }
            }
        }
    }

    /// One named key (`down`, `up`, `tab`, `shiftTab`, `escape`, `delete`, `cmd-f`, `cmd-w`, `cmd-g`, or a character)
    /// delivered to the Settings window.
    private func settingsKey(_ name: String, in w: NSWindow) {
        let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
        let table: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
            "down": (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125, arrows),
            "up": (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126, arrows),
            "tab": ("\t", 48, []), "shiftTab": ("\u{19}", 48, .shift), "escape": ("\u{1B}", 53, []), "delete": ("\u{7F}", 51, []),
            "return": ("\r", 36, []),
            "cmd-f": ("f", 3, .command), "cmd-w": ("w", 13, .command), "cmd-g": ("g", 5, .command), "cmd-a": ("a", 0, .command),
        ]
        let (chars, code, mods) = table[name] ?? (name, name == " " ? 49 : 0, [])
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown, mods.contains(.command) {
                if w.performKeyEquivalent(with: e) { continue }
                if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { continue }
            }
            w.sendEvent(e)
        }
    }

    /// The switches of the shown pane, in form order.
    private func settingsControls() -> [NSControl] {
        var out: [NSControl] = []
        guard let root = settingsController.window?.contentView else { return out }
        root.layoutSubtreeIfNeeded()
        func walk(_ v: NSView) {
            if let c = v as? NSControl, String(describing: type(of: c)).contains("Switch") { out.append(c) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    func settingsAssertions(_ a: [String: Any]) {
        let controller = settingsController
        let model = controller.model
        if let want = a["visible"] as? Bool { check("the Settings window is shown: \(want)", controller.window?.isVisible == want) }
        if let want = a["pane"] as? String { check("Settings shows the \(want) pane", model.pane.rawValue == want, model.pane.rawValue) }
        if let want = a["title"] as? String { check("the Settings title is \(want)", controller.window?.title == want, controller.window?.title ?? "") }
        if let want = a["panes"] as? [String] { check("Settings lists the panes \(want)", model.panes.map(\.rawValue) == want, "\(model.panes.map(\.rawValue))") }
        if let want = a["rows"] as? [String] { check("Settings shows the rows \(want)", model.rows.map(\.title) == want, "\(model.rows.map(\.title))") }
        if let want = a["query"] as? String { check("the search field holds \(want.debugDescription)", model.query == want, model.query) }
        if let want = a["nothingFound"] as? Bool {
            check("Settings says nothing matches: \(want)", model.panes.isEmpty == want, "\(model.panes.map(\.rawValue))")
        }
        if let want = a["searchFocused"] as? Bool {
            let focused = (controller.window?.firstResponder as? NSTextView).map { ($0.delegate as? NSSearchField) === controller.searchField && controller.searchField != nil } ?? false
            check("the search field has the keyboard: \(want)", focused == want, "\(String(describing: controller.window?.firstResponder))")
        }
        if let want = a["switches"] as? [Bool] {
            let found = settingsControls().map { $0.integerValue != 0 }
            check("the shown pane's switches are \(want)", found == want, "\(found)")
        }
        // Stored values, by the key they are stored under.
        if let want = a["values"] as? [String: Any] {
            for (key, v) in want.sorted(by: { $0.key < $1.key }) {
                let got = Settings.shared.defaults.object(forKey: key)
                check("setting \(key) is \(v)", "\(got ?? "nil")" == "\(v)", "\(got ?? "nil")")
            }
        }
    }
}
#endif
