import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var fixtureDir: URL { root.appendingPathComponent("fixtures") }
    static func text(_ name: String) throws -> String {
        try String(contentsOf: fixtureDir.appendingPathComponent(name), encoding: .utf8)
    }
}

/// Suites that run again with focus mode and syntax highlighting on set this for their duration: every editor
/// they make starts with both on.
enum TestMode {
    nonisolated(unsafe) static var focusTools = false
}

func isolatedSettings() -> Settings {
    let name = "markdown-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    if TestMode.focusTools {
        d.set(true, forKey: "focusMode")
        d.set(true, forKey: "syntaxHighlight")
    }
    return Settings(defaults: d)
}

struct Editor {
    let session: EditorSession
    let tv: EditorTextView
    let um: UndoManager

    init(text: String = "", settings: Settings = isolatedSettings(), appearance: NSAppearance? = NSAppearance(named: .aqua)) {
        session = EditorSession(settings: settings, forcedAppearance: appearance)
        tv = session.makeTextView()
        um = UndoManager()
        um.groupsByEvent = false
        tv.documentUndoManager = um
        session.load(text)
        XCTAssertTrue(session.waitUntilStyled())
    }

    var string: String { session.text }

    func edit(range: NSRange, with s: String) {
        grouped { _ = tv.replaceThroughUndo(range: range, with: s) }
    }

    func select(_ loc: Int, _ len: Int = 0) { tv.setSelectedRange(NSRange(location: loc, length: len)) }

    /// Runs `body` as one undo group.
    func grouped(_ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    /// Runs a command, then checks undo restores exactly and redo reapplies exactly.
    func roundTrip(_ body: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let before = string
        grouped(body)
        let after = string
        XCTAssertNotEqual(before, after, "the command changed nothing", file: file, line: line)
        um.undo()
        XCTAssertEqual(string, before, "undo", file: file, line: line)
        um.redo()
        XCTAssertEqual(string, after, "redo", file: file, line: line)
    }

    /// Per-character signature of everything the styler sets.
    func signature() -> [String] {
        let s = session.storage
        var out: [String] = []
        out.reserveCapacity(s.length)
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { attrs, r, _ in
            let font = attrs[.font] as? NSFont
            let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
            let bg = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB)
            let p = attrs[.paragraphStyle] as? NSParagraphStyle
            let sig = "\(font?.fontName ?? "-")/\(font?.pointSize ?? 0)|\(color?.hexString ?? "-")|\(bg?.hexString ?? "-")|\(p?.headIndent ?? -1)/\(p?.lineSpacing ?? -1)/\(p?.paragraphSpacingBefore ?? -1)|\(attrs[.strikethroughStyle] ?? 0)"
            out.append(contentsOf: Array(repeating: sig, count: r.length))
        }
        return out
    }
}

extension Editor {
    /// An editor sized to `width`, with the caret at `caret` (default: the end) and everything laid out.
    static func laidOut(_ text: String, caret: Int? = nil, width: CGFloat = 800) -> Editor {
        let e = Editor(text: text)
        e.tv.setFrameSize(NSSize(width: width, height: 600))
        e.select(caret ?? (text as NSString).length)
        e.settle()
        return e
    }

    /// Waits for styling and for what the selection asks of the core, then lays everything out.
    func settle() {
        _ = session.waitUntilStyled()
        session.refreshState()
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: session.storage.length))
    }

    var lm: EditorLayoutManager { session.layoutManager }

    /// Width of the first line fragment's used rect.
    func firstLineWidth() -> CGFloat {
        var w: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, used, _, _, stop in
            w = used.width
            stop.pointee = true
        }
        return w
    }

    /// Top of the line fragment holding the character at `i`.
    func lineTop(of i: Int) -> CGFloat {
        lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil).minY
    }

    func lineHeight(of i: Int) -> CGFloat {
        lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil).height
    }
}

/// An editor inside a scroll view, and scrolling it to a character.
enum TestScroll {
    /// An editor inside a scroll view of `height` points.
    static func scrolled(_ text: String, height: CGFloat = 400) -> (Editor, NSScrollView) {
        let e = Editor(text: text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: height))
        scroll.documentView = e.tv
        e.tv.setFrameSize(NSSize(width: 800, height: height))
        e.select(0)
        e.settle()
        return (e, scroll)
    }

    static func scroll(_ e: Editor, _ scroll: NSScrollView, toCharacter i: Int) {
        let lm = e.lm
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: i + 1))
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + e.tv.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.session.visibleRangeChanged()
        e.settle()
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "?" }
        return String(format: "%02X%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
    }
}

func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    return condition()
}
