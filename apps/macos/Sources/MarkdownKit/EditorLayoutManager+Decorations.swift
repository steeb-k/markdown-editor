import AppKit

/// Drawing of Live mode's decorations: bullets, checkboxes, rules, quote bars and images. All
/// geometry comes from the visible layout (line fragments and glyph rectangles), never from
/// character counts, so it stays right when markup is hidden, indents hang or lines collapse.
extension EditorLayoutManager {
    /// Called by the text view after the block panels, before the text.
    func drawDecorations(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard !live.decorations.isEmpty, let tc = textContainers.first, let palette else { return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for d in live.decorations where d.range.location < NSMaxRange(chars) && chars.location < NSMaxRange(d.range) {
            switch d.kind {
            case .bullet: drawBullet(d, in: tc, origin: origin, palette: palette)
            case .checkbox(let checked): drawCheckbox(d, checked: checked, in: tc, origin: origin, palette: palette)
            case .rule: drawRule(d, in: tc, origin: origin, palette: palette)
            case .quoteBar(let depth): drawQuoteBar(d, depth: depth, in: tc, origin: origin, palette: palette)
            case .image(let destination, let alt): drawImage(d, destination: destination, alt: alt, in: tc, origin: origin, palette: palette)
            }
        }
    }

    // MARK: geometry

    private struct Anchor {
        var line: NSRect
        var glyphs: NSRect
        var baseline: CGFloat
        var font: NSFont
    }

    private func anchor(of range: NSRange, in tc: NSTextContainer) -> Anchor? {
        guard let storage = textStorage, range.location < storage.length else { return nil }
        let g = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard g.length > 0 else { return nil }
        let line = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
        let glyphs = boundingRect(forGlyphRange: g, in: tc)
        let baseline = line.minY + location(forGlyphAt: g.location).y
        let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? bodyFont
        return Anchor(line: line, glyphs: glyphs, baseline: baseline, font: font)
    }

    static func checkboxSide(for font: NSFont) -> CGFloat { (font.pointSize * 0.74).rounded() }

    /// The box drawn in place of a task item's hidden `- [ ] `: where a bullet's dot would be,
    /// left of the item's text (container coordinates).
    func checkboxFrame(of d: LiveDecoration, in tc: NSTextContainer) -> NSRect? {
        guard let storage = textStorage, let h = RangeList.range(containing: live.hidden, d.range.location),
              NSMaxRange(h) < storage.length else { return nil }
        // The first visible character after the hidden prefix: null glyphs are placed with the
        // previous line when they start a paragraph, so only a visible glyph says where the line is.
        let textStart = NSMaxRange(h)
        guard let a = anchor(of: NSRange(location: textStart, length: 1), in: tc) else { return nil }
        let side = Self.checkboxSide(for: a.font)
        let style = storage.attribute(.paragraphStyle, at: textStart, effectiveRange: nil) as? NSParagraphStyle
        let hang = max(side + 3, style?.firstLineHeadIndent ?? 0)
        let centerY = a.baseline - a.font.xHeight * 0.5
        return NSRect(x: (a.glyphs.minX - hang).rounded(), y: (centerY - side / 2).rounded(), width: side, height: side)
    }

    /// The task marker decoration under `point` (container coordinates), if any.
    func checkbox(at point: NSPoint, in tc: NSTextContainer) -> LiveDecoration? {
        for d in live.decorations {
            guard case .checkbox = d.kind, let frame = checkboxFrame(of: d, in: tc) else { continue }
            if frame.insetBy(dx: -5, dy: -5).contains(point) { return d }
        }
        return nil
    }

    /// All checkbox frames (container coordinates), for cursor rects.
    func checkboxFrames(in tc: NSTextContainer, characterRange chars: NSRange) -> [NSRect] {
        live.decorations.compactMap { d in
            guard case .checkbox = d.kind, d.range.location < NSMaxRange(chars), chars.location < NSMaxRange(d.range) else { return nil }
            return checkboxFrame(of: d, in: tc)
        }
    }

    // MARK: drawing

    private func drawBullet(_ d: LiveDecoration, in tc: NSTextContainer, origin: NSPoint, palette: ThemePalette) {
        guard let a = anchor(of: d.range, in: tc) else { return }
        let diameter = max(4, (a.font.pointSize * 0.3).rounded())
        let x = a.glyphs.minX + a.font.pointSize * 0.06
        let y = a.baseline - a.font.xHeight * 0.5 - diameter / 2
        palette.text.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: x + origin.x, y: y + origin.y, width: diameter, height: diameter)).fill()
    }

    private func drawCheckbox(_ d: LiveDecoration, checked: Bool, in tc: NSTextContainer, origin: NSPoint, palette: ThemePalette) {
        guard let frame = checkboxFrame(of: d, in: tc) else { return }
        let r = frame.offsetBy(dx: origin.x, dy: origin.y)
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
        if checked {
            palette.link.setFill()
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.52))
            check.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.69))
            check.line(to: NSPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.31))
            check.lineWidth = max(1.5, r.width * 0.12)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            palette.background.setStroke()
            check.stroke()
        } else {
            box.lineWidth = 1.25
            palette.markup.setStroke()
            box.stroke()
        }
    }

    private func drawRule(_ d: LiveDecoration, in tc: NSTextContainer, origin: NSPoint, palette: ThemePalette) {
        guard let a = anchor(of: NSRange(location: hostCharacter(of: d.range), length: 1), in: tc) else { return }
        let y = (a.baseline - a.font.xHeight * 0.5).rounded() + 0.5
        let x0 = a.line.minX + origin.x
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: y + origin.y))
        path.line(to: NSPoint(x: x0 + tc.size.width, y: y + origin.y))
        path.lineWidth = 1
        palette.rule.setStroke()
        path.stroke()
    }

    /// The bar beside a quote, on every line whose `>` is hidden; consecutive lines join up.
    private func drawQuoteBar(_ d: LiveDecoration, depth: Int, in tc: NSTextContainer, origin: NSPoint, palette: ThemePalette) {
        guard let storage = textStorage, d.range.location < storage.length else { return }
        let ns = storage.mutableString as NSString
        let range = RangeMath.clamp(d.range, toLength: storage.length)
        let g = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let step = ("> " as NSString).size(withAttributes: [.font: bodyFont]).width
        let barWidth: CGFloat = 3
        let x = (CGFloat(depth) * step + step * 0.22).rounded()
        var run: NSRect?
        func flush() {
            guard let r = run else { return }
            let bar = NSRect(x: x + origin.x, y: r.minY + origin.y, width: barWidth, height: r.height)
            palette.markup.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            run = nil
        }
        enumerateLineFragments(forGlyphRange: g) { [self] rect, _, _, fragGlyphs, _ in
            let chars = characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)
            // First non-blank character of this fragment's paragraph.
            var ps = chars.location
            while ps > 0, ns.character(at: ps - 1) != 0x0A, ns.character(at: ps - 1) != 0x0D { ps -= 1 }
            var q = ps
            while q < storage.length, ns.character(at: q) == 0x20 || ns.character(at: q) == 0x09 { q += 1 }
            let drawn = q < storage.length && ns.character(at: q) == 0x3E && live.isHidden(q)
            if drawn {
                if let r = run, abs(rect.minY - r.maxY) < 1.5 { run = r.union(rect) } else { flush(); run = rect }
            } else {
                flush()
            }
        }
        flush()
    }

    private func drawImage(_ d: LiveDecoration, destination: String, alt: String, in tc: NSTextContainer, origin: NSPoint, palette: ThemePalette) {
        guard let a = anchor(of: NSRange(location: hostCharacter(of: d.range), length: 1), in: tc) else { return }
        let budget = imageBudget()
        let entry = imageEntry?(destination, budget) ?? ImageController.Entry(phase: .loading, image: nil, size: ImageController.placeholderSize(budget))
        let frame = NSRect(x: a.line.minX + origin.x, y: a.line.minY + Self.imagePadding + origin.y,
                           width: entry.size.width, height: entry.size.height)
        let clip = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let image = entry.image {
            clip.addClip()
            NSImage(cgImage: image, size: frame.size).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                                                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return
        }
        // A quiet placeholder: a tinted panel and, once the image is known to be missing, its name.
        palette.codeBackground.setFill()
        clip.fill()
        let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let tint = palette.markup.withAlphaComponent(entry.phase == .loading ? 0.45 : 0.8)
        var textTop = frame.midY
        if let symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .light)
            let img = symbol.withSymbolConfiguration(cfg) ?? symbol
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                tint.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            let hasCaption = entry.phase == .failed
            let iy = hasCaption ? frame.midY - s.height - 1 : frame.midY - s.height / 2
            tinted.draw(in: NSRect(x: frame.midX - s.width / 2, y: iy, width: s.width, height: s.height), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textTop = iy + s.height + 2
        }
        if entry.phase == .failed {
            let caption = alt.isEmpty ? (destination as NSString).lastPathComponent : alt
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(10, bodyFont.pointSize * 0.72)),
                .foregroundColor: palette.markup, .paragraphStyle: para,
            ]
            (caption as NSString).draw(in: NSRect(x: frame.minX + 12, y: textTop, width: frame.width - 24, height: 16), withAttributes: attrs)
        }
    }
}
