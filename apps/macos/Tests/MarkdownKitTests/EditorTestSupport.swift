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

func isolatedSettings() -> Settings {
    let name = "markdown-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    // Most tests are about styled source; Live mode tests ask for it.
    d.set(ViewMode.source.rawValue, forKey: "defaultViewMode")
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
