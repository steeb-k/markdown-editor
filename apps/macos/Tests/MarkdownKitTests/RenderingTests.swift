import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// What ends up on screen: pixels of a text view rendered offscreen.
final class RenderingTests: XCTestCase {
    private func render(_ e: Editor, width: CGFloat = 700) -> NSBitmapImageRep {
        e.tv.setFrameSize(NSSize(width: width, height: 10))
        e.tv.layoutManager?.ensureLayout(for: e.tv.textContainer!)
        e.tv.sizeToFit()
        let rect = e.tv.bounds
        let rep = e.tv.bitmapImageRepForCachingDisplay(in: rect)!
        e.tv.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// Color at a point in view coordinates (flipped, points).
    private func color(_ rep: NSBitmapImageRep, _ view: NSView, _ p: NSPoint) -> NSColor {
        let sx = CGFloat(rep.pixelsWide) / view.bounds.width, sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        return rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))!.usingColorSpace(.sRGB)!
    }

    func testCodeBlockTintIsOneContinuousPanel() throws {
        let e = Editor(text: "Before.\n\n```\nline one\nline two\nline three\n```\n\nAfter.\n")
        let lm = try XCTUnwrap(e.tv.layoutManager as? EditorLayoutManager)
        let rep = render(e)
        let ns = e.string as NSString
        let block = ns.range(of: "```\nline one\nline two\nline three\n```")
        let glyphs = lm.glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        let panels = lm.blockBackgroundRects(forGlyphRange: glyphs)
        XCTAssertEqual(panels.count, 1)
        let panel = try XCTUnwrap(panels.first).0.offsetBy(dx: e.tv.textContainerOrigin.x, dy: e.tv.textContainerOrigin.y)
        let tint = e.session.appearance.palette.codeBackground.usingColorSpace(.sRGB)!
        let bg = e.session.appearance.palette.background.usingColorSpace(.sRGB)!
        // Sample a vertical line through the panel just left of the text: every pixel is tinted
        // (no stripes between lines), and the panel reaches into the margin.
        let x = e.tv.textContainerOrigin.x - 4
        var y = panel.minY + 2
        while y < panel.maxY - 2 {
            XCTAssertEqual(color(rep, e.tv, NSPoint(x: x, y: y)).hexString, tint.hexString, "stripe at y=\(y) in \(panel)")
            y += 1
        }
        XCTAssertEqual(color(rep, e.tv, NSPoint(x: x, y: panel.minY - 3)).hexString, bg.hexString, "above the panel")
        XCTAssertEqual(color(rep, e.tv, NSPoint(x: x, y: panel.maxY + 3)).hexString, bg.hexString, "below the panel")
        // Padding above the first line and below the last is about the same.
        var lines: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in lines.append(used) }
        let top = (lines.first!.minY + e.tv.textContainerOrigin.y) - panel.minY
        let font = try XCTUnwrap(e.session.storage.attribute(.font, at: block.location + 5, effectiveRange: nil) as? NSFont)
        let lastGlyphBottom = lines.last!.minY + e.tv.textContainerOrigin.y + lm.defaultLineHeight(for: font)
        let bottom = panel.maxY - lastGlyphBottom
        XCTAssertEqual(top, bottom, accuracy: 2, "panel padding top \(top) bottom \(bottom)")
    }
}

extension RenderingTests {
    /// Wide characters in a monospaced table still get glyphs (font fallback), and the table's
    /// pipes line up in display columns.
    func testCJKAndEmojiInTablesAreDrawn() throws {
        let e = Editor(text: "| 日本語 | 🎉 |\n| --- | --- |\n| ab | cd |\n")
        let rep = render(e)
        let lm = try XCTUnwrap(e.tv.layoutManager)
        let ns = e.string as NSString
        let cjk = ns.range(of: "日本語")
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: cjk, actualCharacterRange: nil), in: e.tv.textContainer!)
            .offsetBy(dx: e.tv.textContainerOrigin.x, dy: e.tv.textContainerOrigin.y)
        let bg = e.session.appearance.palette.background.usingColorSpace(.sRGB)!.hexString
        var inked = 0
        for x in stride(from: rect.minX + 1, to: rect.maxX - 1, by: 1) {
            for y in stride(from: rect.minY + 2, to: rect.maxY - 2, by: 1) where color(rep, e.tv, NSPoint(x: x, y: y)).hexString != bg {
                inked += 1
            }
        }
        XCTAssertGreaterThan(inked, 20, "CJK glyphs drawn in \(rect)")
    }
}

extension RenderingTests {
    /// The pipes after wide cells line up with the pipes above them, and every row of the table
    /// has the same height.
    func testWideCharactersKeepTablePipesAligned() throws {
        let e = Editor(text: "| 日本 | x |\n| ---- | - |\n| 🎉ab | y |\n| abcd | z |\n")
        _ = render(e)
        let lm = try XCTUnwrap(e.tv.layoutManager)
        let ns = e.string as NSString
        var xs: [CGFloat] = [], heights: [CGFloat] = []
        for line in ns.components(separatedBy: "\n") where !line.isEmpty {
            let start = ns.range(of: line).location
            let second = (line as NSString).range(of: "|", options: [], range: NSRange(location: 1, length: (line as NSString).length - 1)).location
            let g = lm.glyphIndexForCharacter(at: start + second)
            xs.append(lm.location(forGlyphAt: g).x + lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX)
            heights.append(lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).height)
        }
        if ProcessInfo.processInfo.environment["RT_DEBUG"] != nil {
            for i in 0..<ns.length {
                let g = lm.glyphIndexForCharacter(at: i)
                print("RT", i, ns.substring(with: NSRange(location: i, length: 1)), lm.location(forGlyphAt: g).x, e.session.storage.attribute(.kern, at: i, effectiveRange: nil) ?? "-", (e.session.storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.fontName ?? "")
            }
        }
        for x in xs { XCTAssertEqual(x, xs[0], accuracy: 0.6, "pipe columns \(xs)") }
        for h in heights { XCTAssertEqual(h, heights[0], accuracy: 0.5, "row heights \(heights)") }
    }
}

/// The styler works out a range's attributes on a copy and writes the finished runs back
/// (`StagedAttributes`): what lands in the storage must be exactly what changing it in place gives.
final class StagedAttributesTests: XCTestCase {
    private func runs(_ s: NSAttributedString) -> [String] {
        var out: [String] = []
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { attrs, r, _ in
            out.append("\(r): " + attrs.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","))
        }
        return out
    }

    func testStagedChangesEqualChangesInPlace() {
        let text = String(repeating: "# Title\n\nSome *words* and **more** words.\n\n- a list\n\n", count: 30)
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, n))) }
        let fonts = [NSFont.systemFont(ofSize: 13), NSFont.boldSystemFont(ofSize: 15), NSFont.userFixedPitchFont(ofSize: 12)!]
        let colors = [NSColor.red, NSColor.blue, NSColor.textColor]
        for round in 0..<40 {
            let direct = NSTextStorage(string: text, attributes: [.font: fonts[0]])
            // Some runs already there, as in a styled document.
            for _ in 0..<30 { direct.addAttribute(.foregroundColor, value: colors[rnd(3)], range: NSRange(location: rnd(text.count - 20), length: 1 + rnd(15))) }
            let staged = NSTextStorage(attributedString: direct)
            let ns = text as NSString
            let range = ns.paragraphRange(for: NSRange(location: rnd(text.count - 200), length: 1 + rnd(150)))
            let copy = StagedAttributes(staged, range: range)
            for _ in 0..<(5 + rnd(20)) {
                let r = NSRange(location: range.location + rnd(range.length - 1), length: 0)
                let sub = NSRange(location: r.location, length: min(1 + rnd(40), NSMaxRange(range) - r.location))
                switch rnd(4) {
                case 0: let f = fonts[rnd(3)]; direct.setAttributes([.font: f], range: sub); copy.setAttributes([.font: f], range: sub)
                case 1: let c = colors[rnd(3)]; direct.addAttribute(.foregroundColor, value: c, range: sub); copy.addAttribute(.foregroundColor, value: c, range: sub)
                case 2: let f = fonts[rnd(3)]; direct.addAttribute(.font, value: f, range: sub); copy.addAttribute(.font, value: f, range: sub)
                default:
                    direct.enumerateAttribute(.font, in: sub, options: []) { v, s, _ in
                        if let v = v as? NSFont { direct.addAttribute(.font, value: NSFontManager.shared.convert(v, toSize: v.pointSize + 1), range: s) }
                    }
                    copy.enumerateAttribute(.font, in: sub) { v, s, _ in
                        if let v = v as? NSFont { copy.addAttribute(.font, value: NSFontManager.shared.convert(v, toSize: v.pointSize + 1), range: s) }
                    }
                }
            }
            staged.beginEditing()
            copy.write(to: staged)
            staged.endEditing()
            XCTAssertEqual(runs(staged), runs(direct), "round \(round), range \(range)")
            // Writes outside the staged range are ignored, never a crash.
            copy.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: NSMaxRange(range) + 5, length: 3))
            copy.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: max(0, range.location - 5), length: 3))
        }
    }
}
