import AppKit

/// TextKit 1 layout manager. Knows where block backgrounds (code blocks) go: one continuous
/// panel across the text column. It is also Live mode's concealer (see
/// `EditorLayoutManager+Live.swift`): the state the core computed lives in `live`, and the
/// layout manager's delegate methods turn it into null glyphs and collapsed lines without
/// touching the text storage.
public final class EditorLayoutManager: NSLayoutManager {
    /// How far a block panel reaches into the margins, and above/below its text.
    static let blockOutset = NSSize(width: 12, height: 6)
    static let blockCornerRadius: CGFloat = 6

    /// What paints over the stored colours (focus dimming...). Hand-drawn things ask it whether
    /// they are dimmed: they never see temporary attributes.
    weak var overlay: OverlayCompositor?
    /// Instrumentation: how many times AppKit finished a layout pass (focus mode must add none).
    var layoutCompletions = 0
    /// What Live mode currently conceals and decorates. Set through `setLive`.
    public internal(set) var live = LiveState()
    /// Characters whose glyphs `drawGlyphs` skips because a decoration is drawn in their place.
    var markerRanges: [NSRange] = []
    /// Image decorations and collapsed lines, for the line fragment delegate.
    var imageDecorations: [LiveDecoration] = []
    /// Text whose concealment was dropped because an edit touched it: its glyphs are regenerated
    /// with the next state, whether or not that state differs.
    var staleRanges: [NSRange] = []
    /// The hidden `- [ ] ` of each task item: zero width, unlike other hidden leading markup.
    var taskPrefixes: [NSRange] = []
    /// High surrogates at the end of a glyph generation piece, to check (see `checkSplitSurrogate`).
    var splitSurrogates: Set<Int> = []

    /// Set by the session: the room images may take, and what to draw for one.
    var imageBudget: () -> ImageController.Budget = { ImageController.Budget(width: 600, maxHeight: 400) }
    var imageEntry: ((String, ImageController.Budget) -> ImageController.Entry)?
    /// Instrumentation: the character ranges whose glyphs and layout `setLive` invalidated.
    var recordsInvalidations = false
    var invalidatedRanges: [NSRange] = []
    /// Instrumentation: the glyph runs whose backgrounds and strikes were drawn by hand, and the
    /// horizontal extent (container coordinates) each was given. Recorded while non-nil.
    var manualDrawings: [(glyphs: NSRange, x: ClosedRange<CGFloat>)]?
    /// Where the background being drawn is anchored (see `fillBackgroundRectArray`).
    var drawOrigin = NSPoint.zero
    /// Set by the session on every appearance change.
    var palette: ThemePalette?
    var bodyFont: NSFont = .systemFont(ofSize: 17)

    /// Height of a collapsed line (a concealed fence or delimiter), and the breathing room
    /// above and below a drawn image.
    /// How much of an inline-code chip outside the focus range is drawn.
    static let dimmedBackgroundStrength: CGFloat = 0.4
    static let collapsedHeight: CGFloat = 2
    static let fenceCollapsedHeight: CGFloat = 8
    static let imagePadding: CGFloat = 6
    /// Changed paragraphs closer than this are invalidated as one range (see `setLive`).
    static let invalidationGap = 256

    public override init() {
        super.init()
        delegate = self
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    /// The panel rectangles (container coordinates) of the blocks touching `glyphs`.
    func blockBackgroundRects(forGlyphRange glyphs: NSRange) -> [(NSRect, NSColor)] {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return [] }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out: [(NSRect, NSColor)] = []
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
            let concealing = !live.isEmpty
            enumerateLineFragments(forGlyphRange: g) { [self] line, _, _, fragGlyphs, _ in
                if concealing {
                    // Concealed fences take no part in the panel, and a fragment that only
                    // carries the next paragraph's hidden characters is not the block's.
                    let fc = characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)
                    if collapsedLine(inFragment: fc) != nil { return }
                    let inside = NSIntersectionRange(fc, run)
                    if inside.length == 0 || (inside.location..<NSMaxRange(inside)).allSatisfy({ live.isHidden($0) }) { return }
                }
                rect = rect.union(line)
                lastLine = line
            }
            guard !rect.isNull else { continue }
            // The line spacing under the last line is not part of the block: it ends where the
            // last line's glyphs do, so the padding is the same above and below.
            if let font = storage.attribute(.font, at: NSMaxRange(run) - 1, effectiveRange: nil) as? NSFont {
                rect.size.height = min(rect.height, lastLine.minY + defaultLineHeight(for: font) - rect.minY)
            }
            rect.origin.x = 0
            rect.size.width = container.size.width
            out.append((rect.insetBy(dx: -Self.blockOutset.width, dy: -Self.blockOutset.height), color))
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
