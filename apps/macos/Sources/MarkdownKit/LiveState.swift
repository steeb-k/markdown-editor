import Foundation
import MarkdownCore

/// How the editor shows the Markdown. Source dims the markup; Live hides it away from the
/// caret. Split and Preview arrive with the preview milestone: a raw value is all they need.
public enum ViewMode: String, CaseIterable, Sendable {
    case source, live

    public var title: String {
        switch self {
        case .source: return "Source"
        case .live: return "Live"
        }
    }
}

/// What the layout manager draws in place of concealed source. The shell's mirror of the
/// core's `Decoration`, with images resolved to what the image controller needs.
public struct LiveDecoration: Hashable {
    public enum Kind: Hashable {
        case bullet
        case checkbox(checked: Bool)
        case rule
        case image(destination: String, alt: String)
        case quoteBar(depth: Int)
    }
    public var range: NSRange
    public var kind: Kind

    public init(range: NSRange, kind: Kind) { self.range = range; self.kind = kind }
}

/// The result of the core's `concealment` query, in `NSRange`s, plus the helpers the layout
/// manager and the session need. Value type: states are compared to find what changed.
public struct LiveState: Equatable {
    /// Sorted, disjoint.
    public var hidden: [NSRange] = []
    /// Whole lines (terminator included) that take almost no height.
    public var collapsed: [NSRange] = []
    /// Sorted by location.
    public var decorations: [LiveDecoration] = []

    public init() {}

    public var isEmpty: Bool { hidden.isEmpty && collapsed.isEmpty && decorations.isEmpty }

    public init(_ c: Concealment, images: [ImageRef]) {
        hidden = c.hidden.map(\.nsRange)
        collapsed = c.collapsed.map(\.nsRange)
        decorations = c.decorations.map { d in
            let kind: LiveDecoration.Kind
            switch d.kind {
            case .bullet: kind = .bullet
            case .checkbox(let checked): kind = .checkbox(checked: checked)
            case .rule: kind = .rule
            case .image(let index):
                let im = Int(index) < images.count ? images[Int(index)] : nil
                kind = .image(destination: im?.destination ?? "", alt: im?.alt ?? "")
            case .quoteBar(let depth): kind = .quoteBar(depth: Int(depth))
            }
            return LiveDecoration(range: d.range.nsRange, kind: kind)
        }
    }

    /// `old` outside `window` (what an earlier window said about text that has scrolled away
    /// stays true until that text is queried again) plus `new`, which speaks for `window`.
    public static func merged(old: LiveState, new: LiveState, window: NSRange) -> LiveState {
        var out = LiveState()
        out.hidden = RangeList.union(RangeList.subtract(old.hidden, window), new.hidden)
        out.collapsed = RangeList.union(old.collapsed.filter { !intersects($0, window) }, new.collapsed)
        out.decorations = (old.decorations.filter { !intersects($0.range, window) } + new.decorations)
            .sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
        return out
    }

    /// The state after text changed: ranges move with their text, those whose text was
    /// touched go (the next query brings back what is still true).
    ///
    /// Also returns where the dropped ranges' text now is: its glyphs were generated under the old
    /// state and nothing else will make them regenerate.
    public func shifted(through c: TextChange) -> (state: LiveState, dropped: [NSRange]) {
        var s = LiveState()
        var dropped: [NSRange] = []
        func move(_ r: NSRange) -> NSRange? {
            if let n = Self.shift(r, through: c) { return n }
            dropped.append(RangeMath.shift(r, through: c))
            return nil
        }
        s.hidden = hidden.compactMap(move)
        s.collapsed = collapsed.compactMap(move)
        s.decorations = decorations.compactMap { d in move(d.range).map { LiveDecoration(range: $0, kind: d.kind) } }
        return (s, dropped)
    }

    static func shift(_ r: NSRange, through c: TextChange) -> NSRange? {
        let oldEnd = NSMaxRange(c.old)
        if c.old.length == 0 {
            let p = c.old.location
            if p <= r.location { return NSRange(location: r.location + c.delta, length: r.length) }
            if p >= NSMaxRange(r) { return r }
            return nil
        }
        if NSMaxRange(r) <= c.old.location { return r }
        if r.location >= oldEnd { return NSRange(location: r.location + c.delta, length: r.length) }
        return nil
    }

    private static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location < NSMaxRange(b) && b.location < NSMaxRange(a)
    }

    // MARK: lookups

    /// Is the character at `i` hidden?
    public func isHidden(_ i: Int) -> Bool { RangeList.contains(hidden, i) }

    /// The collapsed line containing `i`, if any.
    public func collapsedLine(containing i: Int) -> NSRange? { RangeList.range(containing: collapsed, i) }

    /// Ranges a caret must not rest strictly inside: hidden text, and a task marker together
    /// with the hidden dash before it (the checkbox is one thing to the eye).
    public var atomic: [NSRange] {
        var list = hidden
        for d in decorations {
            guard case .checkbox = d.kind else { continue }
            let i = RangeList.firstIndex(endingAfter: d.range.location - 2, in: hidden)
            if i < hidden.count, d.range.location - NSMaxRange(hidden[i]) <= 1, NSMaxRange(hidden[i]) <= d.range.location {
                list.append(NSUnionRange(hidden[i], d.range))
            } else {
                list.append(d.range)
            }
        }
        return RangeList.normalized(list)
    }
}

/// Operations on sorted, disjoint range lists.
enum RangeList {
    static func contains(_ list: [NSRange], _ i: Int) -> Bool { range(containing: list, i) != nil }

    static func range(containing list: [NSRange], _ i: Int) -> NSRange? {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(list[mid]) <= i { lo = mid + 1 } else { hi = mid }
        }
        return lo < list.count && list[lo].location <= i ? list[lo] : nil
    }

    /// Index of the first range that ends after `i`.
    static func firstIndex(endingAfter i: Int, in list: [NSRange]) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(list[mid]) <= i { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var out: [NSRange] = []
        for r in sorted {
            if let last = out.last, r.location <= NSMaxRange(last) {
                out[out.count - 1] = NSUnionRange(last, r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func union(_ a: [NSRange], _ b: [NSRange]) -> [NSRange] { normalized(a + b) }

    static func subtract(_ list: [NSRange], _ cut: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        for x in list {
            let i = NSIntersectionRange(x, cut)
            if i.length == 0 { out.append(x); continue }
            if i.location > x.location { out.append(NSRange(location: x.location, length: i.location - x.location)) }
            if NSMaxRange(i) < NSMaxRange(x) { out.append(NSRange(location: NSMaxRange(i), length: NSMaxRange(x) - NSMaxRange(i))) }
        }
        return out
    }

    /// Parts of either list not in both.
    static func symmetricDifference(_ a: [NSRange], _ b: [NSRange]) -> [NSRange] {
        if a == b { return [] }
        var out: [NSRange] = []
        for x in a { out += subtractAll(x, b) }
        for x in b { out += subtractAll(x, a) }
        return normalized(out)
    }

    private static func subtractAll(_ r: NSRange, _ list: [NSRange]) -> [NSRange] {
        var pieces = [r]
        var i = firstIndex(endingAfter: r.location, in: list)
        while i < list.count, list[i].location < NSMaxRange(r) {
            pieces = pieces.flatMap { subtract([$0], list[i]) }
            i += 1
        }
        return pieces
    }
}
