import Foundation
import MarkdownCore

/// What the analysis queue hands back: the paragraph-aligned range it re-analyzed and the
/// spans overlapping it. `spans == nil` means "the range is big or the queue is behind; ask
/// for it later". `seq` is the number of the last edit this result reflects.
public struct AnalysisResult {
    public var seq: Int
    public var range: NSRange
    public var spans: [Span]?
    /// The core's prose ranges within `range` (what spell checking may look at).
    public var prose: [Utf16Range] = []
}

/// Owns the core `Document` on its own serial queue (PLAN "Threading"). The text view's
/// storage is the source of truth for text; this object is told every character edit as
/// (range in the old text, replacement) and keeps a private mirror of the text so the queue
/// can widen dirty ranges to paragraphs without touching the main thread.
///
/// The core is called from the main thread only through `sync`, which first lets the queue
/// drain: that is what commands needing a current analysis use.
public final class AnalysisCoordinator {
    /// How long the main thread waits for the result of an edit, so ordinary documents restyle
    /// in the same run-loop turn. Beyond this the result is applied when it arrives.
    public static let defaultSyncWait: TimeInterval = 0.004
    /// Larger dirty ranges are restyled in chunks, not in one go on the main thread.
    public static let maxInlineSpanRange = 24_000

    public var syncWait: TimeInterval = AnalysisCoordinator.defaultSyncWait

    /// Test hook: sleep this long (seconds) at the start of each edit job on the queue.
    public var artificialDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = newValue; lock.unlock() }
    }

    /// Test hook: after every edit, compare the core's text with the queue's mirror and count
    /// the times they differ (the mirror is what dirty ranges are widened against).
    public var verifiesMirror = false
    public var mirrorMismatches: Int { lock.lock(); defer { lock.unlock() }; return _mismatches }
    private var _mismatches = 0

    /// Called on the main thread, in order, with each final result.
    public var onResult: ((AnalysisResult) -> Void)?

    private let queue: DispatchQueue
    // Queue-confined:
    private var document: Document
    private var mirror: NSMutableString
    private var carry: NSRange?
    private var processedSeq = 0
    /// Queue-confined cache for `cachedImages(of:)`.
    var imageCache: (revision: UInt64, images: [ImageRef])?

    // Shared, guarded by `lock`:
    private let lock = NSCondition()
    private var inbox: [AnalysisResult] = []
    private var outstanding = 0
    private var _delay: TimeInterval = 0
    /// How long the last edit's analysis took on the queue.
    private var _lastAnalysis: TimeInterval = 0
    /// Instrumentation: total seconds the queue spent in `process` (the core's replace and the
    /// span fetch), and in the fetch alone; and how many edits that was.
    private var _processTime: TimeInterval = 0
    private var _fetchTime: TimeInterval = 0
    private var _processed = 0
    public var instrumentation: (process: TimeInterval, fetch: TimeInterval, edits: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_processTime, _fetchTime, _processed)
    }
    /// Instrumentation: main-thread seconds spent blocked in `sync`.
    public private(set) var totalSyncTime: TimeInterval = 0

    // Main-thread only:
    private var submittedSeq = 0

    public init(text: String = "", label: String = "markdown.analysis") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        document = Document(text: "")
        mirror = NSMutableString()
        if !text.isEmpty {
            // Built on the queue; every later job queues behind it.
            queue.async { [self] in
                mirror = NSMutableString(string: text)
                document = Document(text: text)
            }
        }
    }

    // MARK: edits

    public var latestSeq: Int { submittedSeq }

    /// True when every edit submitted so far has been processed.
    public var isIdle: Bool { lock.lock(); defer { lock.unlock() }; return outstanding == 0 }

    /// A result is waiting in the inbox for the main thread (`deliverPending`). Idle and nothing
    /// waiting: every edit's result has been handed over.
    public var hasUndelivered: Bool { lock.lock(); defer { lock.unlock() }; return !inbox.isEmpty }

    /// Forwards one character edit (range in the old text, replacement). Returns its number.
    @discardableResult
    public func submit(range: NSRange, replacement: String) -> Int {
        submittedSeq += 1
        let seq = submittedSeq
        lock.lock(); outstanding += 1; lock.unlock()
        queue.async { [self] in process(seq: seq, range: range, replacement: replacement) }
        return seq
    }

    /// Waits up to `syncWait` for the result of edit `seq`, but only when this edit is the only
    /// one in flight (a queue that is behind would just make every keystroke wait). Delivers
    /// whatever has arrived. Main thread.
    /// Instrumentation: main-thread time spent in `waitForResult` so far.
    public private(set) var totalWaitTime: TimeInterval = 0

    public func waitForResult(seq: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { totalWaitTime += CFAbsoluteTimeGetCurrent() - t0 }
        let deadline = Date(timeIntervalSinceNow: syncWait)
        lock.lock()
        // When an analysis takes longer than the wait (a big document), waiting only adds the
        // whole wait to every keystroke: the answer never comes in time. Skip it then.
        if outstanding == 1 && _lastAnalysis <= syncWait {
            while !inbox.contains(where: { $0.seq >= seq }) && outstanding > 0 {
                if !lock.wait(until: deadline) { break }
            }
        }
        lock.unlock()
        deliverPending()
    }

    /// Hands every arrived result to `onResult`. Main thread.
    public func deliverPending() {
        lock.lock()
        let results = inbox
        inbox.removeAll()
        lock.unlock()
        for r in results { onResult?(r) }
    }

    private func process(seq: Int, range: NSRange, replacement: String) {
        let started = CFAbsoluteTimeGetCurrent()
        let delay = artificialDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }

        let change = TextChange(old: range, newLength: (replacement as NSString).length)
        var dirty: NSRange
        if NSMaxRange(range) <= mirror.length {
            mirror.replaceCharacters(in: range, with: replacement)
            if let u = try? document.replace(range: Utf16Range(start: UInt32(range.location), end: UInt32(NSMaxRange(range))), with: replacement) {
                dirty = NSRange(location: Int(u.dirty.start), length: Int(u.dirty.end - u.dirty.start))
            } else {
                // Out of sync with the shell (should not happen): rebuild from the mirror.
                _ = document.setText(text: mirror as String)
                dirty = NSRange(location: 0, length: mirror.length)
            }
        } else {
            dirty = NSRange(location: 0, length: mirror.length)
        }
        processedSeq = seq
        if verifiesMirror, document.text() != mirror as String {
            lock.lock(); _mismatches += 1; lock.unlock()
        }
        // The edited text itself is always restyled, and the paragraph right after it: inserted
        // characters arrive with whatever attributes the text view gave them, and a Return at the
        // end of a heading leaves the heading's old line break (with the heading's paragraph
        // style) as a new empty line, where the core's spans did not change at all.
        let after = min(change.newLength + 1, max(0, mirror.length - range.location))
        dirty = NSUnionRange(dirty, NSRange(location: range.location, length: after))
        let merged = RangeMath.union(carry.map { RangeMath.shift($0, through: change) }, dirty) ?? dirty
        carry = RangeMath.clamp(merged, toLength: mirror.length)

        lock.lock()
        let behind = outstanding > 1
        if behind { outstanding -= 1 }
        _lastAnalysis = CFAbsoluteTimeGetCurrent() - started
        _processTime += _lastAnalysis
        _processed += 1
        lock.unlock()
        if behind { return } // a newer edit is queued; its result will cover this one

        let aligned = paragraphAligned(carry!)
        carry = nil
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let fetched = aligned.length <= Self.maxInlineSpanRange ? fetch(aligned) : nil
        lock.lock(); _fetchTime += CFAbsoluteTimeGetCurrent() - fetchStart; lock.unlock()
        let result = AnalysisResult(seq: seq, range: aligned, spans: fetched?.0, prose: fetched?.1 ?? [])
        // Idle only once the result is in the inbox: `isIdle` (and so `isStyled`) must not be
        // true while the last edit's spans are still being fetched.
        lock.lock()
        inbox.append(result)
        outstanding -= 1
        lock.broadcast()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.deliverPending() }
    }

    private func paragraphAligned(_ r: NSRange) -> NSRange {
        let c = RangeMath.clamp(r, toLength: mirror.length)
        if mirror.length == 0 { return NSRange(location: 0, length: 0) }
        // An empty range at the very end belongs to the last paragraph.
        let probe = c.length == 0 && c.location == mirror.length ? NSRange(location: max(0, c.location - 1), length: 0) : c
        return mirror.paragraphRange(for: probe)
    }

    private func fetch(_ r: NSRange) -> ([Span], [Utf16Range]) {
        let u = Utf16Range(start: UInt32(r.location), end: UInt32(NSMaxRange(r)))
        return (document.spans(within: u), document.proseRanges(within: u))
    }

    // MARK: queries

    /// Runs `body` with the core document after every edit submitted so far has been analyzed.
    /// The one place the main thread touches the core.
    public func sync<R>(_ body: (Document) -> R) -> R {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { totalSyncTime += CFAbsoluteTimeGetCurrent() - t0 }
        return queue.sync { body(document) }
    }

    /// Runs `body` on the queue and returns to the main thread with its result. `edit`
    /// is the number of the last edit submitted when the request was made.
    public func async<R>(_ body: @escaping (Document) -> R, completion: @escaping (R, _ processedSeq: Int) -> Void) {
        queue.async { [self] in
            let r = body(document)
            let s = processedSeq
            DispatchQueue.main.async { completion(r, s) }
        }
    }

    /// Spans for a range owed to the styler (initial pass, theme change, deferred ranges).
    public func spans(in range: NSRange, completion: @escaping (AnalysisResult) -> Void) {
        queue.async { [self] in
            let aligned = paragraphAligned(range)
            let (spans, prose) = fetch(aligned)
            let result = AnalysisResult(seq: processedSeq, range: aligned, spans: spans, prose: prose)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// For tests: the queue's mirror of the text, after draining.
    public func mirrorText() -> String { queue.sync { mirror as String } }
    public func coreText() -> String { queue.sync { document.text() } }
}
