import Foundation

/// A replacement of `old` by `newLength` characters, in the coordinates before the edit.
public struct TextChange: Equatable {
    public var old: NSRange
    public var newLength: Int
    public init(old: NSRange, newLength: Int) { self.old = old; self.newLength = newLength }
    public var delta: Int { newLength - old.length }
}

public enum RangeMath {
    /// Where a range ends up once `change` has happened. A boundary inside the replaced text
    /// collapses to the start (for a start) or to the end (for an end) of the replacement.
    public static func shift(_ r: NSRange, through c: TextChange) -> NSRange {
        let oldEnd = NSMaxRange(c.old)
        func start(_ p: Int) -> Int { p <= c.old.location ? p : (p >= oldEnd ? p + c.delta : c.old.location) }
        func end(_ p: Int) -> Int { p <= c.old.location ? p : (p >= oldEnd ? p + c.delta : c.old.location + c.newLength) }
        let s = start(r.location)
        let e = max(s, end(NSMaxRange(r)))
        return NSRange(location: s, length: e - s)
    }

    /// Where a caret/selection endpoint ends up (a point exactly at an insertion stays before it).
    public static func shiftPoint(_ p: Int, through c: TextChange) -> Int {
        let oldEnd = NSMaxRange(c.old)
        if p <= c.old.location { return p }
        if p >= oldEnd { return p + c.delta }
        return c.old.location + c.newLength
    }

    public static func union(_ a: NSRange?, _ b: NSRange?) -> NSRange? {
        guard let a else { return b }
        guard let b else { return a }
        return NSUnionRange(a, b)
    }

    public static func clamp(_ r: NSRange, toLength n: Int) -> NSRange {
        let s = min(max(r.location, 0), n)
        let e = min(max(NSMaxRange(r), s), n)
        return NSRange(location: s, length: e - s)
    }
}

/// Sorted, disjoint, non-empty ranges. Used for "styling still owed".
public struct RangeSet: Equatable {
    public private(set) var ranges: [NSRange] = []
    public init() {}
    public var isEmpty: Bool { ranges.isEmpty }

    public mutating func add(_ r: NSRange) {
        guard r.length > 0 else { return }
        var merged = r
        var out: [NSRange] = []
        var placed = false
        for x in ranges {
            if NSMaxRange(x) < merged.location {
                out.append(x)
            } else if x.location > NSMaxRange(merged) {
                if !placed { out.append(merged); placed = true }
                out.append(x)
            } else {
                merged = NSUnionRange(merged, x)
            }
        }
        if !placed { out.append(merged) }
        ranges = out
    }

    public mutating func subtract(_ r: NSRange) {
        guard r.length > 0 else { return }
        var out: [NSRange] = []
        for x in ranges {
            let i = NSIntersectionRange(x, r)
            if i.length == 0 { out.append(x); continue }
            if i.location > x.location { out.append(NSRange(location: x.location, length: i.location - x.location)) }
            if NSMaxRange(i) < NSMaxRange(x) { out.append(NSRange(location: NSMaxRange(i), length: NSMaxRange(x) - NSMaxRange(i))) }
        }
        ranges = out
    }

    public mutating func shift(through c: TextChange) {
        let old = ranges
        ranges = []
        for x in old { add(RangeMath.shift(x, through: c)) }
    }

    public mutating func clamp(toLength n: Int) {
        let old = ranges
        ranges = []
        for x in old { add(RangeMath.clamp(x, toLength: n)) }
    }

    public mutating func removeAll() { ranges = [] }

    public func intersection(with r: NSRange) -> [NSRange] {
        ranges.map { NSIntersectionRange($0, r) }.filter { $0.length > 0 }
    }
}
