import AppKit
import XCTest
@testable import MarkdownKit

/// What a release is made of: the menus (key equivalents, actions, standard items), the guide and
/// its generated shortcut table, Info.plist, the entitlements, the acknowledgements.
final class ReleaseTests: XCTestCase {
    private var resources: URL { Fixtures.root.appendingPathComponent("apps/macos/Resources") }

    private func allItems(_ menu: NSMenu, path: String = "") -> [(path: String, item: NSMenuItem)] {
        var out: [(String, NSMenuItem)] = []
        for item in menu.items {
            let p = path + "/" + item.title
            out.append((p, item))
            if let sub = item.submenu { out += allItems(sub, path: p) }
        }
        return out
    }

    // MARK: key equivalents

    func testNoTwoMenuItemsShareAKeyEquivalent() {
        _ = NSApplication.shared
        var seen: [String: String] = [:]
        for (path, item) in allItems(MainMenu.build()) where !item.keyEquivalent.isEmpty {
            // (An alternate item shares its key with the item it replaces while Option is held.)
            let key = "\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)-\(item.keyEquivalent.lowercased())"
            if item.isAlternate { continue }
            if let other = seen[key] { XCTFail("\(path) and \(other) share a key equivalent") }
            seen[key] = path
        }
    }

    func testNoKeyEquivalentShadowsASystemOne() {
        _ = NSApplication.shared
        let items = allItems(MainMenu.build())
        // Combinations the system owns. Where the app has the matching standard command it may use the
        // key for it (`owner`); every other use is a shadow.
        struct Reserved { var key: String; var mods: NSEvent.ModifierFlags; var owner: Selector? }
        let reserved: [Reserved] = [
            Reserved(key: "h", mods: .command, owner: #selector(NSApplication.hide(_:))),
            Reserved(key: "h", mods: [.command, .option], owner: #selector(NSApplication.hideOtherApplications(_:))),
            Reserved(key: "m", mods: .command, owner: #selector(NSWindow.performMiniaturize(_:))),
            Reserved(key: "q", mods: .command, owner: #selector(NSApplication.terminate(_:))),
            Reserved(key: "w", mods: .command, owner: #selector(NSWindow.performClose(_:))),
            Reserved(key: ",", mods: .command, owner: #selector(AppDelegate.showSettings(_:))),
            Reserved(key: "f", mods: [.command, .control], owner: #selector(NSWindow.toggleFullScreen(_:))),
            Reserved(key: "`", mods: .command, owner: nil),
            Reserved(key: " ", mods: .command, owner: nil),
            Reserved(key: " ", mods: [.command, .control], owner: nil),
            Reserved(key: " ", mods: [.command, .option], owner: nil),
            Reserved(key: "d", mods: [.command, .option], owner: nil),
            Reserved(key: "\t", mods: .command, owner: nil),
            Reserved(key: "\u{1b}", mods: [.command, .option], owner: nil),
            Reserved(key: "3", mods: [.command, .shift], owner: nil),
            Reserved(key: "4", mods: [.command, .shift], owner: nil),
            Reserved(key: "5", mods: [.command, .shift], owner: nil),
            Reserved(key: "q", mods: [.command, .control], owner: nil),
            Reserved(key: "q", mods: [.command, .shift], owner: nil),
            Reserved(key: "d", mods: [.command, .control], owner: nil),
            Reserved(key: "e", mods: [.command, .control], owner: nil),
        ]
        for r in reserved {
            for (path, item) in items where item.keyEquivalent.lowercased() == r.key
                && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == r.mods {
                XCTAssertEqual(item.action, r.owner, "\(path) uses \(HelpDocuments.display(keyEquivalent: r.key, modifiers: r.mods)), which the system owns")
            }
        }
    }

    // MARK: actions

    func testEveryMenuItemHasAnActionSomeoneHandles() {
        _ = NSApplication.shared
        // The responder chain of a document window, and the application: one of them must answer each action.
        let responders: [AnyClass] = [
            NSApplication.self, AppDelegate.self, NSDocumentController.self, MarkdownDocument.self, NSWindow.self,
            EditorWindowController.self, EditorTextView.self, NSTextView.self, NSText.self, NSResponder.self,
        ]
        for (path, item) in allItems(MainMenu.build()) where !item.isSeparatorItem && item.submenu == nil {
            guard let action = item.action else { XCTFail("\(path) has no action"); continue }
            XCTAssertTrue(responders.contains { $0.instancesRespond(to: action) }, "nothing handles \(action) (\(path))")
        }
    }

    func testTheStandardMenusAreThere() throws {
        _ = NSApplication.shared
        let main = MainMenu.build()
        func menu(_ title: String) throws -> NSMenu { try XCTUnwrap(main.items.first { $0.title == title }?.submenu, title) }
        func titles(_ m: NSMenu) -> [String] { m.items.map(\.title) }
        XCTAssertEqual(main.items.map(\.title).dropFirst(), ["File", "Edit", "Format", "Table", "View", "Window", "Help"])
        let app = try XCTUnwrap(main.items.first?.submenu)
        XCTAssertTrue(titles(app).contains("Services") && titles(app).contains("Settings…") && titles(app).contains { $0.hasPrefix("About") })
        XCTAssertNotNil(NSApp.servicesMenu)
        let edit = try menu("Edit")
        for t in ["Find", "Spelling", "Substitutions", "Transformations", "Speech", "Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] {
            XCTAssertTrue(titles(edit).contains(t), "Edit lacks \(t)")
        }
        let find = try XCTUnwrap(edit.items.first { $0.title == "Find" }?.submenu)
        XCTAssertEqual(titles(find), ["Find…", "Find and Replace…", "Find Next", "Find Previous", "Use Selection for Find", "Jump to Selection"])
        let window = try menu("Window")
        for t in ["Minimize", "Zoom", "Show Tab Bar", "Show All Tabs", "Bring All to Front"] { XCTAssertTrue(titles(window).contains(t), "Window lacks \(t)") }
        XCTAssertTrue(NSApp.windowsMenu === window)
        let help = try menu("Help")
        XCTAssertEqual(titles(help).filter { !$0.isEmpty }, ["Markdown Help", "Markdown Syntax Reference", "Acknowledgements"])
        XCTAssertTrue(NSApp.helpMenu === help, "a help menu registered with the application gets the search field")
    }

    // MARK: the guide

    func testTheShortcutTableIsReadFromTheMenus() {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let table = HelpDocuments.shortcuts(of: menu)
        var expected = 0
        for (path, item) in allItems(menu) where !item.keyEquivalent.isEmpty && !item.isAlternate && item.submenu == nil && !path.isEmpty {
            expected += 1
            let name = String(path.dropFirst()).replacingOccurrences(of: "/", with: " > ").replacingOccurrences(of: "…", with: "")
            XCTAssertEqual(table[name], HelpDocuments.display(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask), name)
        }
        XCTAssertEqual(table.count, expected, "every shortcut is in the table once")
        XCTAssertEqual(table["Format > Strong"], "⌘B")
        XCTAssertEqual(table["Edit > Paste As > AI"], "⇧⌘V")
        XCTAssertEqual(table["Edit > Paste As > Reference"], "⌃⌘V")
        XCTAssertEqual(table["View > Focus Mode"], "⌘D")
        XCTAssertEqual(table["View > Source"], "⌥⌘1")
        XCTAssertEqual(table["View > Enter Full Screen"], "⌃⌘F")
        XCTAssertEqual(table["Window > Show Tab Bar"], "⇧⌘\\")
    }

    func testTheGuideHasItsTableAndNothingLeftOver() throws {
        _ = NSApplication.shared
        let template = try String(contentsOf: resources.appendingPathComponent("Welcome.md"), encoding: .utf8)
        XCTAssertEqual(template.components(separatedBy: HelpDocuments.shortcutsPlaceholder).count, 2, "the placeholder appears once")
        let text = HelpDocuments.welcomeText(template: template, menu: MainMenu.build())
        XCTAssertFalse(text.contains("{{"))
        XCTAssertTrue(text.contains("| Format > Strong | ⌘B |"))
        XCTAssertTrue(text.hasPrefix("# Welcome to Markdown"))
        // The guide is Markdown the core understands: it has a table, a task list, a footnote, a fenced block.
        XCTAssertTrue(text.contains("| Mark       | Means"))
        XCTAssertTrue(text.contains("- [ ] ") && text.contains("[^1]:") && text.contains("```swift"))
    }

    func testFirstRunWindowSizeIsSensible() {
        let small = EditorWindowController.defaultContentSize(for: NSSize(width: 1280, height: 695))
        XCTAssertLessThanOrEqual(small.height, 695 * 0.9 + 1)
        XCTAssertLessThanOrEqual(small.width, 1280 * 0.9 + 1)
        XCTAssertEqual(EditorWindowController.defaultContentSize(for: NSSize(width: 1512, height: 944)), NSSize(width: 860, height: 740))
        let big = EditorWindowController.defaultContentSize(for: NSSize(width: 3440, height: 1415))
        XCTAssertGreaterThan(big.width, 860)
        XCTAssertLessThanOrEqual(big.width, 1100)
        XCTAssertLessThanOrEqual(big.height, 1415 * 0.9 + 1)
        XCTAssertEqual(EditorWindowController.defaultContentSize(for: nil), NSSize(width: 860, height: 740))
    }

    @MainActor
    func testTheSmallestWindowStillHoldsItsControls() throws {
        _ = NSApplication.shared
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("# x\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(wc.window)
        // (The accessory holding the buttons and switches; the title bar view itself is the window's width.)
        let controls = wc.titlebarControls.map(\.frame.width).filter { $0 < window.frame.width }.max() ?? 0
        XCTAssertGreaterThan(controls, 200)
        // The title-bar controls beside the three window buttons, and the formatting bar, fit the narrowest window.
        XCTAssertGreaterThanOrEqual(window.minSize.width, controls + 150, "minimum \(window.minSize.width) for controls \(controls) wide")
        XCTAssertGreaterThanOrEqual(window.minSize.width, wc.toolbar.fittingSize.width + 32)
        doc.close()
    }

    // MARK: Info.plist, entitlements, acknowledgements

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertNotNil(Int(plist["CFBundleVersion"] as? String ?? ""), "the build number is numeric")
        XCTAssertEqual(plist["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
        XCTAssertEqual(plist["NSHumanReadableCopyright"] as? String, "© 2026 Steve Kaznak")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "Markdown")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "io.github.steeb-k.Markdown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("Markdown.icns").path))
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types.compactMap { $0["CFBundleTypeRole"] as? String }, ["Editor", "Editor"])
        XCTAssertEqual(types.first?["LSItemContentTypes"] as? [String], ["net.daringfireball.markdown"])
        // The system's own net.daringfireball.markdown claims .md and .markdown only, and wins over an
        // import: the other extensions need a type of the app's own, a kind of Markdown.
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertEqual(exported.first?["UTTypeIdentifier"] as? String, "io.github.steeb-k.markdown.extensions")
        XCTAssertEqual(exported.first?["UTTypeConformsTo"] as? [String], ["net.daringfireball.markdown", "public.plain-text"])
        let own = try XCTUnwrap(exported.first?["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(own["public.filename-extension"] as? [String], ["mdown", "mkd", "mkdn", "mdwn"])
        XCTAssertEqual(types.first?["LSHandlerRank"] as? String, "Default")
        XCTAssertEqual(types.last?["LSItemContentTypes"] as? [String], ["public.plain-text"])
        let icon = try XCTUnwrap(types.first?["CFBundleTypeIconFile"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(icon + ".icns").path))
        let imported = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertEqual(imported.first?["UTTypeIdentifier"] as? String, "net.daringfireball.markdown")
        XCTAssertEqual(imported.first?["UTTypeConformsTo"] as? [String], ["public.plain-text"])
        let tags = try XCTUnwrap(imported.first?["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["md", "markdown"])
        // The document class every type names exists.
        XCTAssertNotNil(NSClassFromString(try XCTUnwrap(types.first?["NSDocumentClass"] as? String)))
    }

    func testEntitlementsAreMinimal() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Markdown.entitlements"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertTrue(plist.isEmpty, "an entitlement needs a reason that is written in Markdown.entitlements: \(plist.keys)")
    }

    func testAcknowledgementsNameEveryKindOfComponent() throws {
        let text = try String(contentsOf: resources.appendingPathComponent("Acknowledgements.md"), encoding: .utf8)
        for needle in ["SIL OPEN FONT LICENSE", "Reserved Font Name", "pulldown-cmark", "syntect", "two-face", "unicode-segmentation", "unicode-width",
                       "sha2", "toml ", "serde ", "uniffi ", "Mozilla Public License", "Apache License", "MIT License"] {
            XCTAssertTrue(text.contains(needle), "Acknowledgements.md does not mention \(needle)")
        }
        // The notices of the bundled syntax definitions (two-face's own data).
        XCTAssertTrue(text.contains("## Syntax highlighting definitions") && text.contains("#### Mit"))
    }
}
