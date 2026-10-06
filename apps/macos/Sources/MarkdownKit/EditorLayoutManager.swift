import AppKit

/// TextKit 1 layout manager. Knows where block backgrounds (code blocks) go: one continuous
/// panel across the text column, and draws the backgrounds that focus mode dims (see
/// `EditorLayoutManager+Backgrounds.swift`).
public final class EditorLayoutManager: NSLayoutManager {
    /// How far a block panel reaches into the margins, and above/below its text.
    static let blockOutset = NSSize(width: 12, height: 6)
    static let blockCornerRadius: CGFloat = 6

    /// What paints over the stored colours (focus dimming...). Hand-drawn things ask it whether
    /// they are dimmed: they never see temporary attributes.
    weak var overlay: OverlayCompositor?
    /// Instrumentation: how many times AppKit finished a layout pass (focus mode must add none).
    var layoutCompletions = 0
    /// Where the background being drawn is anchored (see `fillBackgroundRectArray`).
    var drawOrigin = NSPoint.zero
    /// Set by the session on every appearance change.
    var palette: ThemePalette?
    var bodyFont: NSFont = .systemFont(ofSize: 17)

    /// How much of an inline-code chip outside the focus range is drawn.
    static let dimmedBackgroundStrength: CGFloat = 0.4

    public override init() {
        super.init()
        delegate = self
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    /// How far in a block's panel starts: the container prefix before its opening fence (blanks,
    /// quote markers, a list marker), so a code block in a list item or a quote starts at the item's
    /// or the quote's text, as the preview's does. Measured in the block's own (monospaced) font,
    /// the font its lines' prefixes are laid out in.
    private func blockIndent(of run: NSRange, in storage: NSTextStorage) -> CGFloat {
        let ns = storage.mutableString as NSString
        guard run.location < ns.length else { return 0 }
        var i = ns.lineRange(for: NSRange(location: run.location, length: 0)).location
        var columns = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x09 { columns += 4 } else if c == 0x20 || c == 0x3E || c == 0x2D || c == 0x2A || c == 0x2B || c == 0x2E || c == 0x29 || (0x30...0x39).contains(c) { columns += 1 } else { break }
            i += 1
        }
        // Only a fenced block: an indented one has its indentation as code.
        guard i + 2 < ns.length, (ns.character(at: i) == 0x60 || ns.character(at: i) == 0x7E),
              ns.character(at: i + 1) == ns.character(at: i), ns.character(at: i + 2) == ns.character(at: i) else { return 0 }
        guard columns > 0, let font = storage.attribute(.font, at: min(run.location, ns.length - 1), effectiveRange: nil) as? NSFont else { return 0 }
        return (CGFloat(columns) * (" " as NSString).size(withAttributes: [.font: font]).width).rounded()
    }

    /// A code block's panel (container coordinates), the characters it covers, the language to badge it
    /// with and where its first visible line is (see `EditorLayoutManager+CodeBadge.swift`).
    struct BlockPanel {
        var rect: NSRect
        var color: NSColor
        var run: NSRange
        var language: String?
        var firstLine: (line: NSRect, textEnd: CGFloat, characters: NSRange)?
    }

    /// The panel rectangles (container coordinates) of the blocks touching `glyphs`.
    func blockBackgroundRects(forGlyphRange glyphs: NSRange) -> [(NSRect, NSColor)] {
        blockPanels(forGlyphRange: glyphs).map { ($0.rect, $0.color) }
    }

    func blockPanels(forGlyphRange glyphs: NSRange) -> [BlockPanel] {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return [] }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out: [BlockPanel] = []
        // A little past both ends: a panel reaches beyond its lines, into a neighbour's redraw.
        var loc = max(0, chars.location - 2)
        let end = min(NSMaxRange(chars) + 2, storage.length)
        while loc < end {
            var run = NSRange(location: 0, length: 0)
            // Always the whole block, even when only part of it is redrawn: corners belong at
            // its real ends, not at the edge of the dirty rectangle.
            let limit = NSRange(location: max(0, loc - 50_000), length: min(storage.length, loc + 50_000) - max(0, loc - 50_000))
            let value = storage.attribute(.markdownBlockBackground, at: loc, longestEffectiveRange: &run, in: limit)
            defer { loc = max(loc + 1, NSMaxRange(run)) }
            guard let color = value as? NSColor, run.length > 0 else { continue }
            let g = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var rect = NSRect.null
            var lastLine = NSRect.null
            var firstLine: (line: NSRect, textEnd: CGFloat, characters: NSRange)?
            enumerateLineFragments(forGlyphRange: g) { [self] line, used, _, fragGlyphs, _ in
                if firstLine == nil { firstLine = (line, used.maxX, characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)) }
                rect = rect.union(line)
                lastLine = line
            }
            if rect.isNull {
                continue
            } else if let font = storage.attribute(.font, at: NSMaxRange(run) - 1, effectiveRange: nil) as? NSFont {
                // The line spacing under the last line is not part of the block: it ends where the
                // last line's glyphs do, so the padding is the same above and below.
                rect.size.height = min(rect.height, lastLine.minY + defaultLineHeight(for: font) - rect.minY)
            }
            // A block inside a list item starts at the item's text, as the preview's does: the
            // width of the blanks before its opening fence, in the code font.
            let indent = blockIndent(of: run, in: storage)
            rect.origin.x = indent
            rect.size.width = max(0, container.size.width - indent)
            let language = storage.attribute(.markdownCodeLanguage, at: run.location, effectiveRange: nil) as? String
            out.append(BlockPanel(rect: rect.insetBy(dx: -Self.blockOutset.width, dy: -Self.blockOutset.height), color: color,
                                  run: run, language: language, firstLine: firstLine))
        }
        return out
    }

    /// Called by the text view after it has drawn its background and before the text (an
    /// override of `drawBackground(forGlyphRange:at:)` is painted over by the view background).
    func drawBlockBackgrounds(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        for (rect, color) in blockBackgroundRects(forGlyphRange: glyphs) {
            color.setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y),
                         xRadius: Self.blockCornerRadius, yRadius: Self.blockCornerRadius).fill()
        }
    }
}
