import AppKit
import MarkdownCore

extension NSAttributedString.Key {
    /// Text the core calls prose (spell checking is limited to it).
    public static let markdownProse = NSAttributedString.Key("MarkdownProse")
    /// A block background (code blocks) drawn across the whole column by `EditorLayoutManager`.
    public static let markdownBlockBackground = NSAttributedString.Key("MarkdownBlockBackground")
}

/// Maps core spans to text attributes. It touches exactly the range it is given (the dirty
/// range, widened to whole paragraphs by the analysis queue) and never registers undo,
/// because it only changes attributes of the text storage.
public final class Styler {
    public var appearance: EditorAppearance {
        didSet { prefixWidthCache.removeAll() }
    }

    /// Live mode hides the whole `- [ ] ` of a task item and draws a checkbox in the bullet's
    /// place, so a task paragraph hangs like a bullet item: the text starts where a bullet
    /// item's would. (The same in every caret position; only the mode changes it.)
    public var liveMode = false

    /// Instrumentation: every range this styler has rewritten, in order.
    public var recordsTouchedRanges = false
    public private(set) var touchedRanges: [NSRange] = []
    public func resetTouchedRanges() { touchedRanges.removeAll() }

    private var prefixWidthCache: [String: CGFloat] = [:]

    public init(appearance: EditorAppearance) { self.appearance = appearance }

    public static func headingScale(_ level: UInt8) -> CGFloat {
        switch level {
        case 1: return 1.7
        case 2: return 1.4
        case 3: return 1.2
        case 4: return 1.1
        default: return 1.0
        }
    }

    /// Rewrites the attributes of `range` from `spans` (which must cover it: every span that
    /// overlaps it, in the core's sorted order). `insideProcessing` is true when called from
    /// `didProcessEditing`, where begin/endEditing must not be used.
    public func style(_ textStorage: NSTextStorage, range requested: NSRange, spans: [Span], prose: [NSRange] = [],
                      insideProcessing: Bool) {
        let range = RangeMath.clamp(requested, toLength: textStorage.length)
        guard range.length > 0 else { return }
        if recordsTouchedRanges { touchedRanges.append(range) }
        let ns = textStorage.mutableString as NSString
        // The attributes are worked out on a copy of the range's paragraphs (everything below writes
        // there) and written back as finished runs: see `StagedAttributes`.
        let storage = StagedAttributes(textStorage, range: ns.paragraphRange(for: range))
        defer {
            if !insideProcessing { textStorage.beginEditing() }
            storage.write(to: textStorage)
            if !insideProcessing { textStorage.endEditing() }
        }

        let a = appearance
        let fonts = a.fonts
        let p = a.palette
        storage.setAttributes(a.baseAttributes(), range: range)

        func clip(_ s: Span) -> NSRange {
            NSIntersectionRange(NSRange(location: Int(s.range.start), length: Int(s.range.end - s.range.start)), range)
        }
        func mapFonts(_ r: NSRange, _ f: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: r, options: []) { v, sub, _ in
                if let font = v as? NSFont { storage.addAttribute(.font, value: f(font), range: sub) }
            }
        }
        func monoSize() -> CGFloat { FontSet.isMonospaced(fonts.body) ? fonts.size : (fonts.size * 0.92).rounded() }
        func monoFont(like f: NSFont, size: CGFloat? = nil) -> NSFont {
            fonts.variant(of: fonts.mono, bold: fonts.isBold(f), italic: fonts.isItalic(f), size: size ?? f.pointSize * (FontSet.isMonospaced(fonts.body) ? 1 : 0.92))
        }
        func eachParagraph(_ r: NSRange, _ body: (NSRange) -> Void) {
            var loc = r.location
            while loc < NSMaxRange(r) {
                let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                if pr.length == 0 { break }
                body(pr)
                loc = NSMaxRange(pr)
            }
        }
        func setParagraph(_ r: NSRange, _ style: NSParagraphStyle) {
            eachParagraph(r) { storage.addAttribute(.paragraphStyle, value: style, range: $0) }
        }

        var tables: [(NSRange, NSFont)] = []

        // Pass 1: faces, colors and paragraph structure.
        for span in spans {
            let r = clip(span)
            guard r.length > 0 else { continue }
            switch span.kind {
            case .heading(let level):
                let size = (fonts.size * Self.headingScale(level)).rounded()
                let font = fonts.variant(of: fonts.body, bold: true, size: size)
                storage.addAttribute(.font, value: font, range: r)
                storage.addAttribute(.foregroundColor, value: p.heading, range: r)
                let before = level <= 3 ? (size * 0.55).rounded() : (size * 0.35).rounded()
                // A heading in a quote hangs under the quote's text, like the rest of the quote.
                let pr = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
                let hang = quoteHang(of: ns, paragraph: pr)
                setParagraph(r, a.paragraphStyle(font: font, headIndent: hang, spacingBefore: before, spacingAfter: (size * 0.1).rounded(), multiple: 1.3))
            case .emphasis:
                mapFonts(r) { fonts.variant(of: $0, italic: true) }
            case .strong:
                mapFonts(r) { fonts.variant(of: $0, bold: true) }
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .inlineCode:
                mapFonts(r) { monoFont(like: $0) }
                storage.addAttribute(.foregroundColor, value: p.codeText, range: r)
                storage.addAttribute(.backgroundColor, value: p.codeBackground, range: r)
            case .codeBlock:
                let font = fonts.variant(of: fonts.mono, size: monoSize())
                storage.addAttribute(.font, value: font, range: r)
                // The blanks and quote markers before the opening fence are in the code's font too, as
                // they are on the block's other lines (which the block's range includes), so that the
                // fences and the code line up in a list item or a quote.
                if r.location == Int(span.range.start) {
                    let lineStart = ns.lineRange(for: NSRange(location: r.location, length: 0)).location
                    let prefix = NSRange(location: lineStart, length: r.location - lineStart)
                    if prefix.length > 0, ns.substring(with: prefix).allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) {
                        storage.addAttribute(.font, value: font, range: prefix)
                    }
                }
                storage.addAttribute(.foregroundColor, value: p.codeText, range: r)
                // Drawn by the layout manager as one continuous panel (a glyph background would
                // leave stripes between lines).
                storage.addAttribute(.markdownBlockBackground, value: p.codeBackground, range: r)
                // A code line in a quote hangs under the quote's text: its `> ` keeps its width when
                // Live mode hides it (the layout manager keeps a hidden prefix's width only in a
                // hanging paragraph), so the code does not run into the quote's bar.
                let plain = a.paragraphStyle(font: font, multiple: 1.4)
                eachParagraph(r) { pr in
                    let hang = self.quotePrefixWidth(of: ns, paragraph: pr, font: font)
                    storage.addAttribute(.paragraphStyle, value: hang > 0 ? a.paragraphStyle(font: font, headIndent: hang, multiple: 1.4) : plain, range: pr)
                }
            case .table:
                let font = fonts.variant(of: fonts.mono, size: monoSize())
                storage.addAttribute(.font, value: font, range: r)
                // Every row the same height, even one with an emoji (a taller fallback font).
                let ps = a.paragraphStyle(font: font, multiple: 1.4).mutableCopy() as! NSMutableParagraphStyle
                let natural = ceil(font.ascender - font.descender + font.leading)
                ps.minimumLineHeight = natural
                ps.maximumLineHeight = natural
                setParagraph(r, ps)
                tables.append((r, font))
            case .frontMatter:
                let font = fonts.variant(of: fonts.mono, size: (monoSize() * 0.95).rounded())
                storage.addAttribute(.font, value: font, range: r)
                storage.addAttribute(.foregroundColor, value: p.markup, range: r)
                setParagraph(r, a.paragraphStyle(font: font, multiple: 1.4))
            case .link, .image, .footnoteReference:
                storage.addAttribute(.foregroundColor, value: p.link, range: r)
            case .blockQuote:
                storage.addAttribute(.foregroundColor, value: p.quote, range: r)
                eachParagraph(r) { pr in
                    let w = self.prefixWidth(of: ns, paragraph: pr, list: false)
                    storage.addAttribute(.paragraphStyle, value: a.paragraphStyle(font: fonts.body, headIndent: w), range: pr)
                }
            case .listMarker, .taskMarker:
                if case .listMarker = span.kind {
                    let pr = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
                    let w = prefixWidth(of: ns, paragraph: pr, list: true)
                    storage.addAttribute(.paragraphStyle, value: a.paragraphStyle(font: fonts.body, headIndent: w), range: pr)
                } else if liveMode {
                    let pr = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
                    if let (head, first) = taskIndents(of: ns, paragraph: pr) {
                        storage.addAttribute(.paragraphStyle,
                                             value: a.paragraphStyle(font: fonts.body, headIndent: head, firstLineHeadIndent: first), range: pr)
                    }
                }
            case .codeInfo, .linkDestination, .footnoteDefinition, .thematicBreak, .html, .hardBreak,
                 .markup, .tableDelimiterRow, .wikilink, .tag:
                break
            }
        }

        // Font fallback: a face without the glyphs (CJK or emoji in the bundled faces, any monospaced
        // face) must be substituted here. The storage fixes attributes only after character
        // edits; after an attribute-only restyle, wide text would otherwise draw as nothing.
        storage.fixAttributes(in: range)
        // The core pads tables in display columns (CJK and emoji count two). Fallback fonts do
        // not draw them exactly two cells wide, so each wide character is kerned to the grid.
        for (r, font) in tables { alignWideCharacters(storage, ns, in: r, cell: font) }

        // What spell checking may look at.
        for pr in prose {
            let r = NSIntersectionRange(pr, range)
            if r.length > 0 { storage.addAttribute(.markdownProse, value: true, range: r) }
        }

        // Pass 2: markup is dimmed last, so it wins over the color of whatever owns it.
        for span in spans {
            let r = clip(span)
            guard r.length > 0 else { continue }
            switch span.kind {
            case .markup, .codeInfo, .linkDestination, .listMarker, .taskMarker, .tableDelimiterRow,
                 .thematicBreak, .html:
                storage.addAttribute(.foregroundColor, value: p.markup, range: r)
            default: break
            }
        }
    }

    private func alignWideCharacters(_ storage: StagedAttributes, _ ns: NSString, in r: NSRange, cell font: NSFont) {
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        guard cell > 0 else { return }
        ns.enumerateSubstrings(in: r, options: .byComposedCharacterSequences) { sub, sr, _, _ in
            guard let sub, sub.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return }
            let f = (storage.attribute(.font, at: sr.location, effectiveRange: nil) as? NSFont) ?? font
            let w = (sub as NSString).size(withAttributes: [.font: f]).width
            let cells = (w / cell).rounded()
            guard cells >= 1, abs(w - cells * cell) > 0.25 else { return }
            let target = (w > cell * 1.25 ? 2 : 1) * cell
            // On the whole character: an attribute run must never split a surrogate pair.
            storage.addAttribute(.kern, value: target - w, range: sr)
        }
    }

    /// Width of the quote markers (`> `) a line starts with; 0 when it is not in a quote.
    private func quoteHang(of ns: NSString, paragraph: NSRange) -> CGFloat {
        let line = ns.substring(with: paragraph) as NSString
        var i = 0
        let n = line.length
        func at(_ k: Int) -> unichar { k < n ? line.character(at: k) : 0 }
        while at(i) == 0x20 || at(i) == 0x09 { i += 1 }
        guard at(i) == 0x3E else { return 0 }
        return prefixWidth(of: ns, paragraph: paragraph, list: false)
    }

    /// Width, in `font`, of the quote markers (`>`, the blank after each, blanks before them) a line
    /// starts with; 0 when it is not in a quote.
    private func quotePrefixWidth(of ns: NSString, paragraph: NSRange, font: NSFont) -> CGFloat {
        let n = min(paragraph.length, 64)
        var i = 0
        var quoted = false
        func at(_ k: Int) -> unichar { k < n ? ns.character(at: paragraph.location + k) : 0 }
        while true {
            while at(i) == 0x20 || at(i) == 0x09 { i += 1 }
            guard at(i) == 0x3E else { break }
            quoted = true
            i += 1
            if at(i) == 0x20 { i += 1 }
        }
        guard quoted else { return 0 }
        let prefix = ns.substring(with: NSRange(location: paragraph.location, length: i)).replacingOccurrences(of: "\t", with: "    ")
        return (prefix as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// For a task item in Live mode: where wrapped lines hang (the text after the list marker, as
    /// for a bullet) and how far the first line starts in (the width of the marker and the blank
    /// after it, which is hidden along with the checkbox's `[ ]`).
    private func taskIndents(of ns: NSString, paragraph: NSRange) -> (CGFloat, CGFloat)? {
        let line = ns.substring(with: paragraph) as NSString
        let n = line.length
        func at(_ i: Int) -> unichar { i < n ? line.character(at: i) : 0 }
        func skipBlanks(_ i: inout Int) { while at(i) == 0x20 || at(i) == 0x09 { i += 1 } }
        var i = 0
        skipBlanks(&i)
        while at(i) == 0x3E { // >
            i += 1
            if at(i) == 0x20 { i += 1 }
            let save = i
            skipBlanks(&i)
            if at(i) != 0x3E { i = save }
        }
        skipBlanks(&i)
        let marker = i
        guard at(i) == 0x2D || at(i) == 0x2A || at(i) == 0x2B else { return nil }
        i += 1
        skipBlanks(&i)
        func width(_ end: Int) -> CGFloat {
            let prefix = line.substring(to: end).replacingOccurrences(of: "\t", with: "    ")
            return (prefix as NSString).size(withAttributes: [.font: appearance.fonts.body]).width.rounded(.up)
        }
        let head = width(i)
        return (head, max(0, head - width(marker)))
    }

    /// Width of a line's quote/list prefix in the body font: wrapped lines hang under the text.
    private func prefixWidth(of ns: NSString, paragraph: NSRange, list: Bool) -> CGFloat {
        let line = ns.substring(with: paragraph) as NSString
        let n = line.length
        func at(_ i: Int) -> unichar { i < n ? line.character(at: i) : 0 }
        func skipBlanks(_ i: inout Int) { while at(i) == 0x20 || at(i) == 0x09 { i += 1 } }
        var i = 0
        skipBlanks(&i)
        while at(i) == 0x3E { // >
            i += 1
            if at(i) == 0x20 { i += 1 }
            let save = i
            skipBlanks(&i)
            if at(i) != 0x3E { i = save }
        }
        if list {
            skipBlanks(&i)
            let c = at(i)
            if (c == 0x2D || c == 0x2A || c == 0x2B), at(i + 1) == 0x20 || at(i + 1) == 0x09 {
                i += 1
                skipBlanks(&i)
            } else {
                var j = i
                while at(j) >= 0x30 && at(j) <= 0x39 && j - i < 9 { j += 1 }
                if j > i, at(j) == 0x2E || at(j) == 0x29, at(j + 1) == 0x20 || at(j + 1) == 0x09 {
                    i = j + 1
                    skipBlanks(&i)
                }
            }
            if at(i) == 0x5B, at(i + 2) == 0x5D, at(i + 3) == 0x20 {
                i += 3
                skipBlanks(&i)
            }
        }
        let prefix = line.substring(to: i).replacingOccurrences(of: "\t", with: "    ")
        if let w = prefixWidthCache[prefix] { return w }
        let w = (prefix as NSString).size(withAttributes: [.font: appearance.fonts.body]).width.rounded(.up)
        prefixWidthCache[prefix] = w
        return w
    }
}

/// The attributes of a range of a text storage, worked out on a copy and written back as finished
/// runs.
///
/// NSTextStorage keeps its attribute runs in one array: a change that splits or merges runs moves
/// every run after it. Styling a range in place takes dozens of overlapping changes, each paying for
/// the whole rest of the document: restyling everything (a theme, a font, Source to Live) took 9 s of
/// main-thread time in 12,000-character pieces of up to 190 ms at 1 MB, 36 s at 2 MB and some 15
/// minutes at 10 MB. Written back run by run, a range whose runs keep their shape (any restyle of text
/// already styled) costs almost nothing: 1.3 s instead of 43 s for 2 MB in a benchmark.
/// Writes outside the staged range are ignored (the styler never makes them: it stays within the
/// paragraphs of the range it is given).
final class StagedAttributes {
    private let base: Int
    private let copy: NSMutableAttributedString

    init(_ storage: NSTextStorage, range: NSRange) {
        base = range.location
        copy = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
    }

    private func local(_ r: NSRange) -> NSRange? {
        let l = NSIntersectionRange(NSRange(location: r.location - base, length: r.length), NSRange(location: 0, length: copy.length))
        return l.length > 0 || (r.length == 0 && r.location - base >= 0 && r.location - base <= copy.length) ? l : nil
    }

    func setAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange) {
        if let l = local(range) { copy.setAttributes(attrs, range: l) }
    }

    func addAttribute(_ key: NSAttributedString.Key, value: Any, range: NSRange) {
        if let l = local(range), l.length > 0 { copy.addAttribute(key, value: value, range: l) }
    }

    func attribute(_ key: NSAttributedString.Key, at location: Int, effectiveRange: NSRangePointer?) -> Any? {
        let i = location - base
        guard i >= 0, i < copy.length else { return nil }
        return copy.attribute(key, at: i, effectiveRange: nil)
    }

    func enumerateAttribute(_ key: NSAttributedString.Key, in range: NSRange, options: NSAttributedString.EnumerationOptions = [],
                            using block: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let l = local(range), l.length > 0 else { return }
        copy.enumerateAttribute(key, in: l, options: options) { v, sub, stop in
            block(v, NSRange(location: sub.location + base, length: sub.length), stop)
        }
    }

    func fixAttributes(in range: NSRange) {
        if let l = local(range), l.length > 0 { copy.fixAttributes(in: l) }
    }

    /// Writes the runs into `storage` (the caller brackets this with begin/endEditing when it may).
    func write(to storage: NSTextStorage) {
        guard copy.length > 0, base + copy.length <= storage.length else { return }
        copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length), options: []) { attrs, sub, _ in
            storage.setAttributes(attrs, range: NSRange(location: sub.location + base, length: sub.length))
        }
    }
}
