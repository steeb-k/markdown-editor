import AppKit

/// The bundled guide (`Welcome.md`) and acknowledgements, and the shortcut table the guide ends
/// with, which is read from the real menus so that it cannot drift from them.
public enum HelpDocuments {
    /// Where `Welcome.md` says the generated table goes.
    public static let shortcutsPlaceholder = "{{SHORTCUTS}}"

    /// A bundled text file from the app's Resources, or nil when it is missing (a test host, a
    /// damaged bundle).
    public static func resource(_ name: String, extension ext: String, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The guide with its table of key equivalents filled in from `menu`.
    public static func welcomeText(template: String, menu: NSMenu) -> String {
        template.replacingOccurrences(of: shortcutsPlaceholder, with: shortcutTable(of: menu))
    }

    /// The text of a key equivalent as menus show it: modifiers in the system's order (control,
    /// option, shift, command), then the key.
    public static func display(keyEquivalent key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case "\t": s += "⇥"
        case "\r": s += "↩"
        case "\u{8}", "\u{7f}": s += "⌫"
        case " ": s += "Space"
        default: s += key.uppercased()
        }
        return s
    }

    /// Every menu item that has a key equivalent, as a Markdown table in menu order: where it is,
    /// and what to press. Items are named by their path (`Edit > Paste As > AI`).
    public static func shortcutTable(of menu: NSMenu) -> String {
        var rows: [(path: String, keys: String)] = []
        func walk(_ m: NSMenu, _ path: [String]) {
            for item in m.items where !item.isSeparatorItem {
                let name = item.title.replacingOccurrences(of: "…", with: "")
                if let sub = item.submenu {
                    walk(sub, path + [name])
                } else if !item.keyEquivalent.isEmpty, !item.isAlternate {
                    let full = (path + [name]).joined(separator: " > ")
                    rows.append((full, display(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)))
                }
            }
        }
        for top in menu.items {
            guard let sub = top.submenu else { continue }
            walk(sub, [top.title])
        }
        var out = "| Command | Keys |\n| :------ | :--- |\n"
        for r in rows { out += "| \(r.path.replacingOccurrences(of: "|", with: "\\|")) | \(r.keys) |\n" }
        return out
    }

    /// The pairs of the table, for tests: path to keys.
    public static func shortcuts(of menu: NSMenu) -> [String: String] {
        var out: [String: String] = [:]
        for line in shortcutTable(of: menu).split(separator: "\n").dropFirst(2) {
            let cells = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count == 2 { out[cells[0]] = cells[1] }
        }
        return out
    }
}
