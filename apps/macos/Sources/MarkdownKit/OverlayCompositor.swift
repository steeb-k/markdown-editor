import AppKit
import MarkdownCore

/// What paints a stretch of text on top of its stored colour.
public enum OverlayPaint: Hashable {
    /// Authorship colouring: borrowed text (AI, Reference). Filled by the session from the
    /// core's `Authorship` runs (`setAuthorship`).
    case authorship(AuthorSource)
    /// A part-of-speech colour.
    case pos(PosClass)
    /// Focus mode's dimming of everything outside the focus range.
    case dim
}

/// Whose text an authorship run is. (Text of the user is the base colour: no run.)
public enum AuthorSource: Hashable, CaseIterable {
    case ai, reference
}

/// A stretch of text and what paints it.
public struct OverlayRun: Equatable {
    public var range: NSRange
    public var paint: OverlayPaint
    public init(_ range: NSRange, _ paint: OverlayPaint) { self.range = range; self.paint = paint }
}

/// The inputs of the overlay, one list per layer. Lists are sorted and disjoint.
public struct OverlayLayers: Equatable {
    /// Layer 1 (above the stored colour): borrowed text.
    public var authorship: [OverlayRun] = []
    /// Layer 2: part-of-speech colours.
    public var pos: [OverlayRun] = []
    /// Layer 3, the top: the ranges kept at full strength. Everything else is dimmed, whatever
    /// the layers below say (dimmed text shows no part-of-speech or authorship colour). `nil`:
    /// focus mode is off; empty: everything is dimmed.
    public var focus: [NSRange]?
    public init() {}
}

/// Owns the *temporary foreground colour* of a layout manager and composes everything that
/// paints over the stored colours with a fixed precedence:
///
///     stored (base)  <  authorship  <  part of speech  <  focus dim
///
/// Temporary attributes are not part of the text storage: no undo, no dirty document, no
/// analysis, no layout. The compositor keeps the runs it has applied and, when a layer
/// changes, applies only the *difference* between what is there and what the layers now say,
/// within a window (the visible text and a margin, moved as the view scrolls). Changing the
/// focus range by a sentence therefore touches two stretches of text, not the window.
///
/// It also answers `isDimmed` for the things a layout manager draws by hand (decorations,
/// pictures, strikethrough, inline-code backgrounds), which never see temporary attributes.
///
/// Main thread only.
public final class OverlayCompositor {
    public weak var layoutManager: NSLayoutManager?
    public private(set) var layers = OverlayLayers()
    /// Colours for the paints; changing it repaints what is applied.
    public var palette: ThemePalette? {
        didSet { if palette?.id != oldValue?.id || oldValue == nil { repaint() } }
    }
    /// The visible character range, and the length of the text (set by the session).
    public var visibleRange: () -> NSRange = { NSRange(location: 0, length: 0) }
    public var textLength: () -> Int = { 0 }

    /// What is on the layout manager now (inside `appliedWindow`), sorted and disjoint.
    public private(set) var applied: [OverlayRun] = []
    public private(set) var appliedWindow = NSRange(location: 0, length: 0)
    /// Text that was edited since the last application: whatever AppKit did to its temporary
    /// attributes there is not trusted, they are removed and put back as needed.
    private var dirty: [NSRange] = []
    private var layersChanged = false

    /// Instrumentation (tests and the harness).
    public private(set) var applications = 0
    /// Main-thread time spent following edits and applying, in seconds.
    public private(set) var timeFollowingEdits: TimeInterval = 0
    public private(set) var timeApplying: TimeInterval = 0
    public private(set) var operations = 0
    public private(set) var charactersTouched = 0
    public var recordsOperations = false
    public private(set) var operationLog: [(range: NSRange, paint: OverlayPaint?)] = []
    public func resetInstrumentation() {
        applications = 0; operations = 0; charactersTouched = 0; operationLog = []
    }

    public init() {}

    // MARK: layers

    public func setFocus(_ keep: [NSRange]?) {
        guard keep != layers.focus else { return }
        layers.focus = keep
        layersChanged = true
    }

    public func setPos(_ runs: [OverlayRun]) {
        guard runs != layers.pos else { return }
        layers.pos = runs
        layersChanged = true
    }

    /// Authorship colouring: runs for the text that is not the user's.
    public func setAuthorship(_ runs: [OverlayRun]) {
        guard runs != layers.authorship else { return }
        layers.authorship = runs
        layersChanged = true
    }

    /// Replaces the authorship runs inside `window` only (what changed around an edit), leaving
    /// the rest of the layer as it is: a keystroke in a document with thousands of marks does
    /// not rebuild all of them.
    func patchAuthorship(_ runs: [OverlayRun], in window: NSRange) {
        var updated = Self.subtract(layers.authorship, window)
        updated.append(contentsOf: Self.clip(runs, to: window))
        updated.sort { $0.range.location < $1.range.location }
        updated = Self.merged(updated)
        guard updated != layers.authorship else { return }
        layers.authorship = updated
        layersChanged = true
    }

    public var isFocusing: Bool { layers.focus != nil }

    /// Is any of `range` outside the focus range? (False while focus mode is off.) For hand
    /// drawn things: text that is dimmed draws its bullet, box, bar or picture dimmed too.
    public func isDimmed(_ range: NSRange) -> Bool {
        guard let keep = layers.focus else { return false }
        return !Self.intersects(keep, range)
    }

    /// The authorship colour of the text at `index` (AI, Reference), for hand-drawn things (a
    /// bullet, a checkbox) that sit beside borrowed text. `nil` for the user's own text.
    public func authorshipColor(at index: Int) -> NSColor? {
        let runs = layers.authorship
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(runs[mid].range) <= index { lo = mid + 1 } else { hi = mid }
        }
        guard lo < runs.count, runs[lo].range.location <= index else { return nil }
        return color(for: runs[lo].paint)
    }

    /// Does focus keep any of `range`? (Always true while focus mode is off.)
    public func isLit(_ range: NSRange) -> Bool { !isDimmed(range) }

    /// How `range` divides into lit and dimmed pieces, in order.
    public func pieces(of range: NSRange) -> [(range: NSRange, dimmed: Bool)] {
        guard let keep = layers.focus, range.length > 0 else { return [(range, false)] }
        var out: [(NSRange, Bool)] = []
        var at = range.location
        let end = NSMaxRange(range)
        var i = Self.firstIndex(endingAfter: at, in: keep)
        while at < end {
            if i < keep.count, keep[i].location < end {
                let k = keep[i]
                if k.location > at { out.append((NSRange(location: at, length: k.location - at), true)) }
                let s = max(at, k.location), e = min(end, NSMaxRange(k))
                if e > s { out.append((NSRange(location: s, length: e - s), false)) }
                at = max(at, e)
                i += 1
            } else {
                out.append((NSRange(location: at, length: end - at), true))
                at = end
            }
        }
        return out
    }

    // MARK: edits

    /// The text changed. Everything the layers know moves with it; what lay in the replaced
    /// range is dropped (the next query brings it back) and re-applied from scratch.
    public func noteEdit(_ change: TextChange) {
        guard change.old.length > 0 || change.newLength > 0 else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeFollowingEdits += CFAbsoluteTimeGetCurrent() - t0 }
        layers.authorship = Self.shift(layers.authorship, through: change)
        layers.pos = Self.shift(layers.pos, through: change)
        if let keep = layers.focus { layers.focus = Self.shiftKeeping(keep, through: change) }
        applied = Self.shift(applied, through: change)
        dirty = dirty.map { RangeMath.shift($0, through: change) }
        let touched = NSRange(location: change.old.location, length: change.newLength)
        dirty.append(touched)
        appliedWindow = RangeMath.shift(appliedWindow, through: change)
        layersChanged = true
    }

    /// Forget everything (a new text was loaded).
    public func reset() {
        removeAll()
        layers = OverlayLayers()
        applied = []
        dirty = []
        appliedWindow = NSRange(location: 0, length: 0)
        layersChanged = false
    }

    // MARK: applying

    /// Up to this length the whole text is painted; beyond it, the window around what is visible.
    static let wholeTextLimit = 60_000

    /// The range to keep painted for what is visible: it and a margin, the whole text when that
    /// is short. Sticky: it moves only once the visible text comes within half a margin of its
    /// edge, so ordinary scrolling does not repaint.
    func window(visible: () -> NSRange, length: Int) -> NSRange {
        let whole = NSRange(location: 0, length: length)
        if length <= Self.wholeTextLimit { return whole }
        let visible = visible()
        let margin = max(6_000, visible.length * 2)
        let comfort = NSRange(location: max(0, visible.location - margin / 2),
                              length: min(length, NSMaxRange(visible) + margin / 2) - max(0, visible.location - margin / 2))
        if appliedWindow.length > 0, NSIntersectionRange(appliedWindow, comfort) == comfort { return appliedWindow }
        let start = max(0, visible.location - margin)
        return NSRange(location: start, length: min(length, NSMaxRange(visible) + margin) - start)
    }

    /// Brings the layout manager in line with the layers: recomposes the window and applies the
    /// difference. Cheap when nothing changed.
    public func apply() {
        guard let lm = layoutManager else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeApplying += CFAbsoluteTimeGetCurrent() - t0 }
        let length = textLength()
        let target = window(visible: visibleRange, length: length)
        let moved = target != appliedWindow
        guard layersChanged || moved || !dirty.isEmpty else { return }
        layersChanged = false
        applications += 1
        let window = RangeMath.clamp(target, toLength: length)
        // Edited text: whatever AppKit left there is wiped; the model says nothing is applied.
        for d in dirty {
            let r = RangeMath.clamp(d, toLength: length)
            if r.length > 0 { lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r) }
            applied = Self.subtract(applied, r)
        }
        dirty = []
        let wanted = Self.compose(layers, in: window)
        // Text that was painted and is now outside the window is cleared; text inside is compared.
        let changes = Self.difference(from: applied, to: wanted)
        for (range, paint) in changes {
            let r = RangeMath.clamp(range, toLength: length)
            guard r.length > 0 else { continue }
            operations += 1
            charactersTouched += r.length
            if recordsOperations { operationLog.append((r, paint)) }
            if let paint, let color = color(for: paint) {
                lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r)
            } else {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
            }
        }
        applied = wanted
        appliedWindow = window
    }

    /// What is applied at `index` (inside the window), `nil` for the stored colour.
    public func appliedPaint(at index: Int) -> OverlayPaint? {
        var lo = 0, hi = applied.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(applied[mid].range) <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo < applied.count && applied[lo].range.location <= index ? applied[lo].paint : nil
    }

    /// The colour a paint stands for in the current palette.
    func color(for paint: OverlayPaint) -> NSColor? {
        guard let p = palette else { return nil }
        switch paint {
        case .dim: return p.focusDim
        case .pos(let c):
            switch c {
            case .noun: return p.posNoun
            case .verb: return p.posVerb
            case .adjective: return p.posAdjective
            case .adverb: return p.posAdverb
            case .conjunction: return p.posConjunction
            }
        case .authorship(let a):
            switch a {
            case .ai: return p.authorAI
            case .reference: return p.authorReference
            }
        }
    }

    /// The colours changed: everything applied is painted again.
    private func repaint() {
        guard let lm = layoutManager else { return }
        for run in applied {
            let r = RangeMath.clamp(run.range, toLength: textLength())
            if r.length > 0, let c = color(for: run.paint) {
                lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: r)
            }
        }
    }

    private func removeAll() {
        guard let lm = layoutManager else { return }
        for run in applied {
            let r = RangeMath.clamp(run.range, toLength: textLength())
            if r.length > 0 { lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r) }
        }
    }

    // MARK: composition (pure)

    /// The runs that paint `window`, composed from the layers in their order of precedence.
    /// Sorted, disjoint, adjacent runs of one paint merged.
    public static func compose(_ layers: OverlayLayers, in window: NSRange) -> [OverlayRun] {
        var runs = clip(layers.authorship, to: window)
        runs = overlay(runs, with: clip(layers.pos, to: window))
        if let keep = layers.focus {
            runs = overlay(runs, with: complement(of: keep, in: window).map { OverlayRun($0, .dim) })
        }
        return merged(runs)
    }

    static func clip(_ runs: [OverlayRun], to window: NSRange) -> [OverlayRun] {
        guard window.length > 0 else { return [] }
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(runs[mid].range) <= window.location { lo = mid + 1 } else { hi = mid }
        }
        var out: [OverlayRun] = []
        var i = lo
        while i < runs.count, runs[i].range.location < NSMaxRange(window) {
            let r = NSIntersectionRange(runs[i].range, window)
            if r.length > 0 { out.append(OverlayRun(r, runs[i].paint)) }
            i += 1
        }
        return out
    }

    /// `window` minus `keep`.
    static func complement(of keep: [NSRange], in window: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var at = window.location
        let end = NSMaxRange(window)
        for k in keep {
            if NSMaxRange(k) <= at { continue }
            if k.location >= end { break }
            if k.location > at { out.append(NSRange(location: at, length: k.location - at)) }
            at = max(at, NSMaxRange(k))
        }
        if at < end { out.append(NSRange(location: at, length: end - at)) }
        return out
    }

    /// `upper` painted over `lower`: where both have a run, `upper` wins.
    static func overlay(_ lower: [OverlayRun], with upper: [OverlayRun]) -> [OverlayRun] {
        if upper.isEmpty { return lower }
        var pieces: [OverlayRun] = []
        var j = 0
        for l in lower {
            var start = l.range.location
            let end = NSMaxRange(l.range)
            while j < upper.count, NSMaxRange(upper[j].range) <= start { j += 1 }
            var k = j
            while k < upper.count, upper[k].range.location < end {
                let u = upper[k].range
                if u.location > start { pieces.append(OverlayRun(NSRange(location: start, length: u.location - start), l.paint)) }
                start = max(start, NSMaxRange(u))
                if NSMaxRange(u) >= end { break }
                k += 1
            }
            if start < end { pieces.append(OverlayRun(NSRange(location: start, length: end - start), l.paint)) }
        }
        var out: [OverlayRun] = []
        out.reserveCapacity(pieces.count + upper.count)
        var a = 0, b = 0
        while a < pieces.count || b < upper.count {
            if b == upper.count || (a < pieces.count && pieces[a].range.location < upper[b].range.location) {
                out.append(pieces[a]); a += 1
            } else {
                out.append(upper[b]); b += 1
            }
        }
        return out
    }

    /// Touching runs of one paint become one.
    static func merged(_ runs: [OverlayRun]) -> [OverlayRun] {
        var out: [OverlayRun] = []
        out.reserveCapacity(runs.count)
        for r in runs where r.range.length > 0 {
            if let last = out.last, last.paint == r.paint, NSMaxRange(last.range) == r.range.location {
                out[out.count - 1].range.length += r.range.length
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The stretches where what is painted differs between `old` and `new`, with what they
    /// should be painted now (`nil`: the stored colour). Both lists sorted and disjoint.
    public static func difference(from old: [OverlayRun], to new: [OverlayRun]) -> [(NSRange, OverlayPaint?)] {
        // Every place where either list changes its mind, in order: the two sorted lists of run
        // edges, merged.
        func edges(_ runs: [OverlayRun]) -> [Int] {
            var e: [Int] = []
            e.reserveCapacity(runs.count * 2)
            for r in runs {
                if e.last != r.range.location { e.append(r.range.location) }
                e.append(NSMaxRange(r.range))
            }
            return e
        }
        let (eo, en) = (edges(old), edges(new))
        var points: [Int] = []
        points.reserveCapacity(eo.count + en.count)
        var a = 0, b = 0
        while a < eo.count || b < en.count {
            let p: Int
            if b == en.count || (a < eo.count && eo[a] <= en[b]) { p = eo[a]; a += 1 } else { p = en[b]; b += 1 }
            if points.last != p { points.append(p) }
        }
        a = 0
        b = 0
        var out: [(NSRange, OverlayPaint?)] = []
        func paint(_ runs: [OverlayRun], _ i: inout Int, at p: Int) -> OverlayPaint? {
            while i < runs.count, NSMaxRange(runs[i].range) <= p { i += 1 }
            return i < runs.count && runs[i].range.location <= p ? runs[i].paint : nil
        }
        for k in 0..<max(0, points.count - 1) {
            let from = points[k], to = points[k + 1]
            let was = paint(old, &a, at: from), now = paint(new, &b, at: from)
            guard was != now else { continue }
            if let last = out.last, last.1 == now, NSMaxRange(last.0) == from {
                out[out.count - 1].0.length += to - from
            } else {
                out.append((NSRange(location: from, length: to - from), now))
            }
        }
        return out
    }

    // MARK: moving runs with the text

    /// Runs after an edit: the text of the replaced range is gone from them.
    static func shift(_ runs: [OverlayRun], through c: TextChange) -> [OverlayRun] {
        var out: [OverlayRun] = []
        out.reserveCapacity(runs.count)
        let oldEnd = NSMaxRange(c.old)
        for r in runs {
            let s = r.range.location, e = NSMaxRange(r.range)
            if e <= c.old.location {
                out.append(r)
            } else if s >= oldEnd {
                out.append(OverlayRun(NSRange(location: s + c.delta, length: r.range.length), r.paint))
            } else {
                // Overlaps the replaced text: the parts outside it stay.
                if s < c.old.location { out.append(OverlayRun(NSRange(location: s, length: c.old.location - s), r.paint)) }
                if e > oldEnd { out.append(OverlayRun(NSRange(location: c.old.location + c.newLength, length: e - oldEnd), r.paint)) }
            }
        }
        return out.filter { $0.range.length > 0 }
    }

    /// The focus range after an edit: text typed inside it, or at either edge of it, stays in
    /// it (typing at the end of a sentence must not flash dim before the next query).
    static func shiftKeeping(_ keep: [NSRange], through c: TextChange) -> [NSRange] {
        var out: [NSRange] = []
        for k in keep {
            var r = RangeMath.shift(k, through: c)
            if c.old.length == 0, c.newLength > 0 {
                if c.old.location == NSMaxRange(k) { r = NSRange(location: k.location, length: k.length + c.newLength) }
                if c.old.location == k.location { r = NSRange(location: k.location, length: k.length + c.newLength) }
            }
            if r.length > 0 { out.append(r) }
        }
        return RangeList.normalized(out)
    }

    /// `runs` without `range`.
    static func subtract(_ runs: [OverlayRun], _ range: NSRange) -> [OverlayRun] {
        var out: [OverlayRun] = []
        out.reserveCapacity(runs.count)
        for r in runs {
            let i = NSIntersectionRange(r.range, range)
            if i.length == 0 { out.append(r); continue }
            if i.location > r.range.location { out.append(OverlayRun(NSRange(location: r.range.location, length: i.location - r.range.location), r.paint)) }
            if NSMaxRange(i) < NSMaxRange(r.range) { out.append(OverlayRun(NSRange(location: NSMaxRange(i), length: NSMaxRange(r.range) - NSMaxRange(i)), r.paint)) }
        }
        return out
    }

    // MARK: ranges

    /// First index whose range ends after `p`.
    static func firstIndex(endingAfter p: Int, in ranges: [NSRange]) -> Int {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(ranges[mid]) <= p { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func intersects(_ ranges: [NSRange], _ r: NSRange) -> Bool {
        let i = firstIndex(endingAfter: r.location, in: ranges)
        // An empty range counts where it stands.
        if r.length == 0 { return i < ranges.count && ranges[i].location <= r.location }
        return i < ranges.count && ranges[i].location < NSMaxRange(r)
    }
}
