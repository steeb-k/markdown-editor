import AppKit

/// View > Line Width (PLAN 3.24): three presets for the setting, and under "This Document" the same three written into the
/// front matter, with "Use Setting" to take the key out again. The items are made once, so their shortcuts work with the menu
/// closed; each time it opens, the "Custom (N)" items show for a width that is none of the presets, so the menu never lies.
final class LineWidthMenu: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static let shared = LineWidthMenu()

    static let presets: [(title: String, width: Int)] = [("Narrow", 56), ("Normal", 72), ("Wide", 96)]
    static let customTitle = "Custom"
    /// The action of the header and of the "Custom (N)" items, which are never enabled: every item of a menu has an
    /// action someone handles, and the application's validation is what turns these off.
    static let infoAction = #selector(AppDelegate.lineWidthInfo(_:))

    private var settingCustom: NSMenuItem?
    private var documentCustom: NSMenuItem?

    static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Line Width")
        menu.delegate = shared
        let keys = ["-", "0", "="]
        let mods: NSEvent.ModifierFlags = [.command, .control, .option]
        for (i, p) in presets.enumerated() {
            let item = menu.addItem(withTitle: p.title, action: #selector(AppDelegate.setLineWidthPreset(_:)), keyEquivalent: keys[i])
            item.keyEquivalentModifierMask = mods
            item.tag = p.width
        }
        shared.settingCustom = hiddenCustom(in: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "This Document", action: infoAction, keyEquivalent: "")
        for p in presets {
            let item = menu.addItem(withTitle: p.title, action: #selector(EditorWindowController.setDocumentLineWidth(_:)), keyEquivalent: "")
            item.tag = p.width
            item.indentationLevel = 1
        }
        shared.documentCustom = hiddenCustom(in: menu)
        shared.documentCustom?.indentationLevel = 1
        let use = menu.addItem(withTitle: "Use Setting", action: #selector(EditorWindowController.setDocumentLineWidth(_:)), keyEquivalent: "")
        use.tag = 0
        use.indentationLevel = 1
        return menu
    }

    /// A checked, disabled "Custom (N)" item that is only shown when its width is not a preset.
    private static func hiddenCustom(in menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: customTitle, action: infoAction, keyEquivalent: "")
        item.isHidden = true
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let front = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? EditorWindowController
        refresh(menu, for: front)
    }

    /// Titles and visibility of the "Custom (N)" items, for the document in `controller` (none: no document key).
    func refresh(_ menu: NSMenu, for controller: EditorWindowController?) {
        Self.showCustom(settingCustom, width: Settings.shared.lineWidth)
        Self.showCustom(documentCustom, width: controller?.session.documentLineWidth)
    }

    private static func showCustom(_ item: NSMenuItem?, width: Int?) {
        let custom = width.flatMap { w in presets.contains { $0.width == w } ? nil : w }
        item?.isHidden = custom == nil
        item?.state = custom == nil ? .off : .on
        if let custom { item?.title = "\(customTitle) (\(custom))" }
    }
}

extension AppDelegate {
    /// The header and the Custom items of View > Line Width: nothing to do, and always disabled.
    @objc public func lineWidthInfo(_ sender: Any?) {}

    /// View > Line Width > Narrow, Normal, Wide: the setting, which every window follows.
    @objc public func setLineWidthPreset(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        Settings.shared.lineWidth = item.tag
    }
}

extension EditorWindowController {
    /// View > Line Width > This Document: the item's width becomes the front matter's `line_width:`, 0 (Use Setting) removes it.
    @objc public func setDocumentLineWidth(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        session.setLineWidth(item.tag == 0 ? nil : item.tag)
    }
}
