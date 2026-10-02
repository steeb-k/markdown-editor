import AppKit
import WebKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The preview's type and stylesheet as the page computes them, Copy As in detail, and the
/// layouts' focus, chrome and editing tools.
@MainActor
final class PreviewLookAndLayoutTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private func open(_ text: String, layout: LayoutMode = .split, configure: (Settings) -> Void = { _ in }) throws -> (MarkdownDocument, EditorWindowController) {
        let settings = isolatedSettings()
        settings.defaultLayout = layout
        configure(settings)
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        if layout.showsPreview { XCTAssertTrue(wc.previewController.waitUntilSettled()) }
        return (doc, wc)
    }

    // MARK: fonts

    /// The bundled faces reach the page through the scheme and are the ones it draws with: its
    /// computed family names them, the font is loaded, and for the monospaced face an `i` is as
    /// wide as an `M` (it would not be in the fallback).
    func testTheBundledFontsAreTheOnesThePageDrawsWith() throws {
        // The test runner is not the app bundle: register the faces and serve them from the source tree.
        let fonts = Fixtures.root.appendingPathComponent("apps/macos/Resources/Fonts")
        let files = try FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ttf" }
        if !FontStore.bundledFontsAvailable { CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil) }
        guard FontStore.bundledFontsAvailable else { throw XCTSkip("the bundled fonts are not in this checkout") }
        for choice in [FontChoice.iaMono, .iaDuo, .iaQuattro] {
            let (doc, wc) = try open("Some *text* and `code`.\n\n```\nfn main() {}\n```\n", layout: .editor, configure: { $0.fontChoice = choice })
            let p = wc.previewController
            p.schemeHandler.fontDirectory = fonts
            doc.session.setLayout(.split)
            XCTAssertTrue(p.waitUntilSettled())
            let family = PreviewTypography.bundledFamilies[choice]!
            XCTAssertTrue(spin(timeout: 10) { (p.evaluateSync("return document.fonts.check('16px \"' + f + '\"');", arguments: ["f": family]) as? Bool) == true }, "\(family) loaded")
            _ = p.evaluateSync("await document.fonts.ready; return 1;")
            let computed = p.evaluateSync("return getComputedStyle(document.querySelector('p')).fontFamily;") as? String ?? ""
            XCTAssertTrue(computed.hasPrefix("\"\(family)\""), "\(choice): \(computed)")
            let widths = p.evaluateSync("""
                const m = (s, f) => { const e = document.createElement('span'); e.textContent = s; e.style.font = '20px ' + f; e.style.whiteSpace = 'pre'; document.body.append(e); const w = e.getBoundingClientRect().width; e.remove(); return w; };
                const f = '"' + family + '", serif';
                return [m('iiiiiiiiii', f), m('MMMMMMMMMM', f), m('iiiiiiiiii', 'serif')];
                """, arguments: ["family": family]) as? [Double] ?? []
            XCTAssertEqual(widths.count, 3)
            if choice == .iaMono, widths.count == 3 {
                XCTAssertEqual(widths[0], widths[1], accuracy: 0.5, "monospaced: \(widths)")
            }
            if widths.count == 3 { XCTAssertNotEqual(widths[0], widths[2], accuracy: 0.5, "not the fallback: \(widths)") }
            XCTAssertTrue(p.schemeHandler.requests.contains { $0.path.hasPrefix("/font/") }, "served through the scheme")
            // Code is set in the mono stack.
            let code = p.evaluateSync("return getComputedStyle(document.querySelector('pre code')).fontFamily;") as? String ?? ""
            XCTAssertTrue(code.contains("Mono") || code.contains("monospace"), "code: \(code)")
            doc.close()
        }
    }

    // MARK: the stylesheet, as the page reads it

    func testTheStylesheetParsesAndGivesEachRoleItsThemeColour() throws {
        let md = "# Heading\n\nA [link](https://x.y) and `code`.\n\n> quote\n\n```rust\nfn a() { let s = \"x\"; }\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n"
        for theme in [ThemeChoice.light, .dark, .sepia] {
            let (doc, wc) = try open(md, configure: { $0.theme = theme; $0.lineWidth = 64 })
            let p = wc.previewController
            let palette = doc.session.appearance.palette
            func rgb(_ c: NSColor) -> String {
                let s = c.usingColorSpace(.sRGB)!
                return "rgb(\(Int((s.redComponent * 255).rounded())), \(Int((s.greenComponent * 255).rounded())), \(Int((s.blueComponent * 255).rounded())))"
            }
            let got = p.evaluateSync("""
                const cs = (sel, prop) => getComputedStyle(document.querySelector(sel))[prop];
                return {
                  bg: cs('body', 'backgroundColor'), text: cs('p', 'color'), heading: cs('h1', 'color'), link: cs('a', 'color'),
                  codeBg: cs('pre', 'backgroundColor'), quoteBorder: cs('blockquote', 'borderLeftColor'),
                  measure: cs('#md', 'maxWidth'), keyword: cs('pre .s-storage, pre .s-keyword', 'color'), string: cs('pre .s-string', 'color'),
                  rules: document.styleSheets[0].cssRules.length,
                  print: [...document.styleSheets[0].cssRules].some(r => r.media && r.media.mediaText === 'print'),
                };
                """) as? [String: Any] ?? [:]
            XCTAssertEqual(got["bg"] as? String, rgb(palette.background), "\(theme) background")
            XCTAssertEqual(got["text"] as? String, rgb(palette.text), "\(theme) text")
            XCTAssertEqual(got["heading"] as? String, rgb(palette.heading), "\(theme) heading")
            XCTAssertEqual(got["link"] as? String, rgb(palette.link), "\(theme) link")
            XCTAssertEqual(got["codeBg"] as? String, rgb(palette.codeBackground), "\(theme) code background")
            XCTAssertEqual(got["quoteBorder"] as? String, rgb(palette.rule), "\(theme) quote bar")
            XCTAssertNotEqual(got["keyword"] as? String, got["text"] as? String, "\(theme): keywords are coloured")
            XCTAssertNotEqual(got["string"] as? String, got["keyword"] as? String, "\(theme): strings differ from keywords")
            XCTAssertTrue((got["measure"] as? String ?? "").hasSuffix("px"), "the measure resolves")
            XCTAssertGreaterThan(got["rules"] as? Int ?? 0, 40, "the stylesheet parsed into its rules")
            XCTAssertEqual(got["print"] as? Bool, true, "with its print section")
            doc.close()
        }
    }

    /// The system appearance changing moves a window on the System theme between Light and Dark,
    /// and the page follows.
    func testTheSystemAppearanceReachesThePage() throws {
        let (doc, wc) = try open("text\n", configure: { $0.theme = .system })
        let p = wc.previewController
        func bg() -> String { p.evaluateSync("return getComputedStyle(document.body).backgroundColor;") as? String ?? "" }
        let light = ThemeStore.windowAppearance(for: .light)
        let dark = ThemeStore.windowAppearance(for: .dark)
        NSApp.appearance = light
        doc.session.refreshAppearance()
        XCTAssertTrue(p.waitUntilSettled())
        let first = bg()
        NSApp.appearance = dark ?? NSAppearance(named: .darkAqua)
        doc.session.refreshAppearance()
        XCTAssertTrue(spin(timeout: 5) { bg() != first }, "the page's background follows (\(first))")
        NSApp.appearance = nil
        doc.close()
    }

    // MARK: Copy As

    func testCopyAsCoversSelectionsTablesListsAndKeepsEditorColoursOut() throws {
        let md = "# Title\n\nFirst *italic* and **bold** with a [link](https://example.com) and `mono`.\n\n- one\n- two\n  - nested\n\n1. first\n2. second\n\n| Left | Right |\n|:-----|------:|\n| a | 1 |\n| b | 2 |\n\nLast paragraph.\n"
        let (doc, wc) = try open(md, layout: .editor)
        let session = doc.session
        // Everything the editor paints over the text is on: focus, parts of speech, authorship.
        session.setFocusEnabled(true)
        session.setSyntaxEnabled(true)
        wc.textView.setSelectedRange((md as NSString).range(of: "First *italic*"))
        wc.textView.markAsAI(nil)
        pump(0.3)
        let pb = NSPasteboard(name: NSPasteboard.Name("copy-as-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let ns = md as NSString
        // A word inside one block: that block.
        XCTAssertTrue(session.copyAs(.html, range: NSRange(location: ns.range(of: "bold").location, length: 2), to: pb))
        let one = try XCTUnwrap(pb.string(forType: .html))
        XCTAssertTrue(one.contains("<strong>bold</strong>") && !one.contains("Title") && !one.contains("Last paragraph"), one)
        // Across blocks: those blocks.
        XCTAssertTrue(session.copyAs(.html, range: NSRange(location: ns.range(of: "bold").location, length: ns.range(of: "nested").location - ns.range(of: "bold").location), to: pb))
        let across = try XCTUnwrap(pb.string(forType: .html))
        XCTAssertTrue(across.contains("<strong>bold</strong>") && across.contains("<li>nested</li>") && !across.contains("first</li>"), across)
        // In a table cell: the table.
        XCTAssertTrue(session.copyAs(.html, range: NSRange(location: ns.range(of: "| b |").location + 2, length: 1), to: pb))
        let table = try XCTUnwrap(pb.string(forType: .html))
        XCTAssertTrue(table.hasPrefix("<meta charset=\"utf-8\"><table>") && table.contains("text-align: right"), table)
        // Rich text of the whole document.
        XCTAssertTrue(session.copyAs(.richText, range: NSRange(location: 0, length: 0), to: pb))
        // HTML, RTF and text (and the legacy aliases AppKit adds for them), nothing private.
        let types = Set((pb.types ?? []).map(\.rawValue))
        XCTAssertTrue(types.isSuperset(of: ["public.html", "public.rtf", "public.utf8-plain-text"]), "\(types)")
        XCTAssertTrue(types.allSatisfy { $0.hasPrefix("public.") || $0.hasPrefix("CorePasteboardFlavorType") || $0.hasPrefix("NeXT") || $0.hasPrefix("Apple ") || $0.hasPrefix("NSStringPboardType") }, "\(types)")
        let rich = try XCTUnwrap(NSAttributedString(rtf: try XCTUnwrap(pb.data(forType: .rtf)), documentAttributes: nil))
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            let r = (rich.string as NSString).range(of: word)
            return r.location == NSNotFound ? [:] : rich.attributes(at: r.location, effectiveRange: nil)
        }
        XCTAssertTrue((attributes(of: "bold")[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true, "bold")
        XCTAssertTrue((attributes(of: "italic")[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true, "italic")
        XCTAssertNotNil(attributes(of: "link")[.link], "link")
        XCTAssertTrue((attributes(of: "mono")[.font] as? NSFont)?.isFixedPitch == true, "code font")
        let lists = (attributes(of: "nested")[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
        XCTAssertEqual(lists.count, 2, "a nested list item is in two lists")
        XCTAssertFalse(((attributes(of: "second")[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []).isEmpty, "the numbered list is a list")
        XCTAssertNotNil((attributes(of: "Right")[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock, "the table is a table")
        // No colour of the editor's: not the AI tint, not focus dimming, not a part-of-speech colour.
        let editorColours = [session.appearance.palette.authorAI, session.appearance.palette.focusDim, session.appearance.palette.posNoun, session.appearance.palette.posVerb].compactMap { $0.usingColorSpace(.sRGB) }
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let c = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            for e in editorColours where abs(c.redComponent - e.redComponent) < 0.01 && abs(c.greenComponent - e.greenComponent) < 0.01 && abs(c.blueComponent - e.blueComponent) < 0.01 {
                XCTFail("an editor colour reached the pasteboard on \((rich.string as NSString).substring(with: range).debugDescription)")
            }
        }
        XCTAssertNil(pb.data(forType: AuthorshipPasteboard.type))
        XCTAssertFalse((pb.string(forType: .string) ?? "").contains("Annotations"))
        doc.close()
    }

    // MARK: layouts

    func testFocusChromeAndEditingToolsFollowTheLayout() throws {
        let (doc, wc) = try open("# Title\n\nSome text to find, and more text.\n", layout: .editor, configure: { $0.autoHideChrome = true })
        wc.showWindow(nil)
        let window = try XCTUnwrap(wc.window)
        for layout in [LayoutMode.split, .preview, .editor, .preview, .split] {
            doc.session.setLayout(layout)
            pump(0.1)
            let responder = window.firstResponder
            if layout == .preview {
                XCTAssertTrue((responder as? NSView)?.isDescendant(of: wc.previewController.webView) == true || responder === wc.previewController.webView, "\(layout): the preview has the keyboard (\(String(describing: responder)))")
            } else {
                XCTAssertTrue(responder === wc.textView, "\(layout): the editor has the keyboard (\(String(describing: responder)))")
            }
        }
        // In the preview, the chrome does not hide (nothing is typed), and comes back on a pointer move.
        doc.session.setLayout(.preview)
        wc.simulatePointerMoved()
        pump(0.1)
        XCTAssertTrue(wc.chromeVisible)
        XCTAssertTrue(wc.toolbar.isHidden, "no formatting toolbar over a preview")
        // Split: Live mode, focus, syntax and authorship all work in the editor half.
        doc.session.setLayout(.split)
        doc.session.setViewMode(.live)
        doc.session.setFocusEnabled(true)
        doc.session.setSyntaxEnabled(true)
        wc.textView.setSelectedRange(NSRange(location: 9, length: 4))
        wc.textView.markAsAI(nil)
        pump(0.5)
        XCTAssertEqual(doc.session.viewMode, .live)
        XCTAssertTrue(doc.session.focusEnabled && doc.session.syntaxEnabled)
        XCTAssertTrue(doc.session.authorship.hasMarks())
        XCTAssertTrue(wc.previewController.waitUntilSettled())
        XCTAssertFalse(wc.previewController.lastBodyHTML.contains("Annotations"), "marks never reach the preview")
        // The find bar works in the editor half.
        wc.textView.window?.makeFirstResponder(wc.textView)
        let find = NSMenuItem(title: "Find", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        wc.textView.performTextFinderAction(find)
        pump(0.2)
        XCTAssertTrue(wc.scrollView.isFindBarVisible, "the find bar shows over the editor")
        XCTAssertFalse(wc.previewPane.isHidden)
        // Editing commands are off in the preview layout and back in split.
        let strong = NSMenuItem(title: "Strong", action: #selector(EditorTextView.toggleStrong(_:)), keyEquivalent: "")
        XCTAssertTrue(wc.textView.validateUserInterfaceItem(strong))
        doc.session.setLayout(.preview)
        XCTAssertFalse(wc.textView.validateUserInterfaceItem(strong))
        doc.close()
    }

    /// Each window has its own preview: switching between documents (tabs) shows each its own text.
    func testTwoDocumentsTwoPreviews() throws {
        let (a, wa) = try open("# Alpha document\n")
        let (b, wb) = try open("# Bravo document\n")
        wa.textView.insertText(" more", replacementRange: NSRange(location: 16, length: 0))
        XCTAssertTrue(wa.previewController.waitUntilSettled() && wb.previewController.waitUntilSettled())
        XCTAssertTrue(wa.previewController.lastBodyHTML.contains("Alpha document more"))
        XCTAssertTrue(wb.previewController.lastBodyHTML.contains("Bravo document") && !wb.previewController.lastBodyHTML.contains("Alpha"))
        a.close()
        b.close()
    }
}
