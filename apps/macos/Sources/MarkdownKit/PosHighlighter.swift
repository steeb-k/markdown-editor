import AppKit
import MarkdownCore
import NaturalLanguage

/// One word the tagger found: where it is in the unit's joined text, and its class.
public struct PosWord: Equatable {
    public var range: NSRange
    public var posClass: PosClass
    public init(range: NSRange, posClass: PosClass) { self.range = range; self.posClass = posClass }
}

/// The platform service the core does not provide: tags words. On macOS it is `NLTagger`; tests
/// substitute their own. `tag` is called from one background queue only.
public protocol PosTagger: AnyObject {
    /// Can this language be tagged at all? (Asked once per language, on the main thread for the
    /// document's language and on the tagging queue for a paragraph in another language.)
    func supports(_ language: NLLanguage) -> Bool
    /// The words of `text` that belong to one of the five classes (others are left out), in order.
    func tag(_ text: String, language: NLLanguage) -> [PosWord]
}

/// `NLTagger` with the `.lexicalClass` scheme.
///
/// What is coloured, as a writing app would: nouns (names of people and places are nouns to the
/// lexical-class scheme too), verbs, adjectives, adverbs and conjunctions. Pronouns,
/// determiners, prepositions, particles, numbers, interjections, classifiers, idioms and
/// unclassified words stay uncoloured, and whitespace and punctuation are not words at all
/// (`omitWhitespace`, `omitPunctuation`; `joinNames` is off, so a full name is two words).
public final class NLPosTagger: PosTagger {
    private var tagger: NLTagger?

    public init() {}

    public static func posClass(of tag: NLTag) -> PosClass? {
        switch tag {
        case .noun: return .noun
        case .verb: return .verb
        case .adjective: return .adjective
        case .adverb: return .adverb
        case .conjunction: return .conjunction
        default: return nil
        }
    }

    public func supports(_ language: NLLanguage) -> Bool {
        NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
    }

    public func tag(_ text: String, language: NLLanguage) -> [PosWord] {
        let t = tagger ?? NLTagger(tagSchemes: [.lexicalClass])
        tagger = t
        t.string = text
        let whole = text.startIndex..<text.endIndex
        t.setLanguage(language, range: whole)
        var out: [PosWord] = []
        t.enumerateTags(in: whole, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, let c = Self.posClass(of: tag) { out.append(PosWord(range: NSRange(range, in: text), posClass: c)) }
            return true
        }
        return out
    }
}

/// Parts-of-speech highlighting ("Syntax"): colours nouns, verbs, adjectives, adverbs and
/// conjunctions through the overlay compositor.
///
/// * The core says what to tag (`posUnits`: one unit per block, its prose only); the tagger
///   runs on a background queue, one unit at a time, nearest the visible text first.
/// * Results are cached by the unit's *content* (its joined text, its layout of pieces and the
///   language), as tags relative to the unit. Scrolling back, edits elsewhere, and a paragraph
///   that moves never tag again; an edit tags the edited unit only. Because the cache is
///   content-addressed a result can never land on text that changed in the meantime: it is
///   simply not looked up.
/// * Work no longer wanted (the text scrolled away, a newer request) is dropped from the queue
///   before it is tagged. Nothing here blocks typing: while the analysis queue is busy, or text
///   is being composed, a request waits.
/// * The language comes from `NLLanguageRecognizer` on a sample of the prose, re-evaluated
///   after a good deal of editing, never per keystroke. A language the tagger cannot do shows no
///   colours and does not loop.
public final class PosHighlighter {
    struct Key: Hashable { var hash: Int; var length: Int }

    /// A tag relative to the start of its unit.
    struct Relative { var location: Int; var length: Int; var posClass: PosClass }

    enum Status: Equatable {
        case off
        case working
        case colored
        case unsupported(String)
    }

    private unowned let session: EditorSession
    public var tagger: PosTagger
    /// Tests pin the language; otherwise it is recognized.
    public var languageOverride: NLLanguage?

    public private(set) var isEnabled = false
    public private(set) var classes: Set<PosClass> = []
    private(set) var status: Status = .off
    public private(set) var language: NLLanguage?
    private var languageStamp = Date.distantPast
    private var editedSinceLanguage = 0
    private var supported: [NLLanguage: Bool] = [:]

    private var cache: [Key: [Relative]] = [:]
    static let cacheLimit = 40_000

    /// Instrumentation. Counted on the tagger's queue under `lock`.
    public var taggerInvocations: Int { lock.lock(); defer { lock.unlock() }; return _invocations }
    public private(set) var cacheHits = 0
    public private(set) var cacheMisses = 0
    public private(set) var refreshes = 0
    /// Main-thread time spent here (seconds): following edits, looking at the text, storing results.
    public private(set) var timeOnMain: TimeInterval = 0
    private var _invocations = 0

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "markdown.pos", qos: .utility)
    private var work: [(key: Key, unit: PosUnit, text: String)] = []
    private var draining = false
    private var tagging = 0
    private var pendingStores = 0
    private var scheduled: DispatchWorkItem?

    public init(session: EditorSession, tagger: PosTagger = NLPosTagger()) {
        self.session = session
        self.tagger = tagger
    }

    deinit {
        scheduled?.cancel()
        lock.lock(); work = []; lock.unlock()
    }

    // MARK: switches

    public func configure(enabled: Bool, classes: Set<SyntaxClass>) {
        let newClasses = Set(classes.map(Self.posClass))
        let changedClasses = newClasses != self.classes
        self.classes = newClasses
        if enabled != isEnabled {
            isEnabled = enabled
            if enabled {
                status = .working
                schedule(after: 0)
            } else {
                dropWork()
                scheduled?.cancel()
                status = .off
                session.overlay.setPos([])
                session.overlay.apply()
            }
        } else if enabled, changedClasses {
            schedule(after: 0)
        }
    }

    static func posClass(_ c: SyntaxClass) -> PosClass {
        switch c {
        case .noun: return .noun
        case .verb: return .verb
        case .adjective: return .adjective
        case .adverb: return .adverb
        case .conjunction: return .conjunction
        }
    }

    // MARK: triggers

    /// Text changed: the overlay has already moved and cut the colours; tagging follows once
    /// typing pauses.
    func noteEdit(_ change: TextChange) {
        guard isEnabled else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeOnMain += CFAbsoluteTimeGetCurrent() - t0 }
        editedSinceLanguage += change.newLength + change.old.length
        schedule(after: 0.15)
    }

    /// The visible text moved.
    func viewportChanged() {
        guard isEnabled else { return }
        schedule(after: 0.05)
    }

    /// Everything is forgotten (a new text was loaded).
    func reset() {
        dropWork()
        scheduled?.cancel()
        session.overlay.setPos([])
        language = nil
        languageStamp = .distantPast
        editedSinceLanguage = 0
        if isEnabled { schedule(after: 0.05) }
    }

    /// Nothing is scheduled, queued or being tagged.
    public var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduled == nil && work.isEmpty && !draining && tagging == 0 && !inFlightQuery && pendingStores == 0
    }
    private var inFlightQuery = false

    private func schedule(after delay: TimeInterval) {
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock(); scheduled = nil; lock.unlock()
            refresh()
        }
        lock.lock(); scheduled = item; lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func dropWork() {
        lock.lock(); work = []; lock.unlock()
    }

    // MARK: asking the core, consulting the cache

    /// Tag what is on screen and around it.
    private func refresh() {
        guard isEnabled else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeOnMain += CFAbsoluteTimeGetCurrent() - t0 }
        let coordinator = session.coordinator
        // Typing and composing come first: ask again shortly.
        if !coordinator.isIdle || session.isComposing() {
            schedule(after: 0.08)
            return
        }
        refreshes += 1
        let visible = session.visibleRange()
        let length = session.storage.length
        let margin = max(6_000, visible.length * 2)
        let start = max(0, visible.location - margin)
        let window = NSRange(location: start, length: min(length, NSMaxRange(visible) + margin) - start)
        let within = Utf16Range(start: UInt32(window.location), end: UInt32(NSMaxRange(window)))
        lock.lock(); inFlightQuery = true; lock.unlock()
        coordinator.async({ doc in doc.posUnits(within: within) }) { [weak self] units, processed in
            guard let self else { return }
            lock.lock(); inFlightQuery = false; lock.unlock()
            guard isEnabled else { return }
            guard processed == session.coordinator.latestSeq else {
                schedule(after: 0.05) // an edit slipped in: the units are out of date
                return
            }
            consume(units, visible: visible)
        }
    }

    private func consume(_ allUnits: [PosUnit], visible: NSRange) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeOnMain += CFAbsoluteTimeGetCurrent() - t0 }
        let ns = session.storage.mutableString as NSString
        // The units nearest the visible text first, and not too many.
        let center = visible.location + visible.length / 2
        func distance(_ u: PosUnit) -> Int {
            let s = Int(u.range.start), e = Int(u.range.end)
            return center < s ? s - center : (center > e ? center - e : 0)
        }
        var units = allUnits
        if units.count > 800 { units = Array(units.sorted { distance($0) < distance($1) }.prefix(800)).sorted { $0.range.start < $1.range.start } }

        guard let lang = resolveLanguage(units: units, ns: ns) else {
            status = .unsupported("unknown")
            session.overlay.setPos([])
            session.overlay.apply()
            return
        }
        guard languageIsSupported(lang) else {
            status = .unsupported(lang.rawValue)
            session.overlay.setPos([])
            session.overlay.apply()
            return
        }

        var runs: [OverlayRun] = []
        var misses: [(key: Key, unit: PosUnit, text: String)] = []
        var missed: [NSRange] = []
        var seen = Set<Key>()
        for u in units {
            let text = Self.joinedText(of: u, in: ns)
            let key = Self.key(for: text, unit: u, language: lang)
            if let tags = cache[key] {
                cacheHits += 1
                let base = Int(u.range.start)
                for t in tags where classes.contains(t.posClass) {
                    runs.append(OverlayRun(NSRange(location: base + t.location, length: t.length), .pos(t.posClass)))
                }
            } else {
                missed.append(NSRange(location: Int(u.range.start), length: Int(u.range.end - u.range.start)))
                if seen.insert(key).inserted {
                    cacheMisses += 1
                    misses.append((key, u, text))
                }
            }
        }
        // A unit that has to be tagged again (it was edited) keeps the colours it had, moved with
        // its text, until the new ones arrive: nothing flickers while typing.
        if !missed.isEmpty {
            let old = session.overlay.layers.pos
            for m in missed {
                runs.append(contentsOf: OverlayCompositor.clip(old, to: m))
            }
            runs.sort { $0.range.location < $1.range.location }
        }
        session.overlay.setPos(runs)
        session.overlay.apply()
        status = misses.isEmpty ? .colored : .working

        // Replace what was queued: work for text that is no longer wanted is cancelled.
        lock.lock()
        work = misses.sorted { distance($0.unit) < distance($1.unit) }
        let start = !draining && !work.isEmpty
        if start { draining = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain(language: lang) } }
    }

    static func joinedText(of u: PosUnit, in ns: NSString) -> String {
        let s = NSMutableString()
        for (i, p) in u.prose.enumerated() {
            if i > 0, u.separated[i] { s.append(" ") }
            s.append(ns.substring(with: p.nsRange))
        }
        return s as String
    }

    static func key(for text: String, unit u: PosUnit, language: NLLanguage) -> Key {
        var h = Hasher()
        h.combine(text)
        h.combine(language.rawValue)
        // How the text is cut into pieces decides where its words land in the document.
        var at = Int(u.range.start)
        for (i, p) in u.prose.enumerated() {
            h.combine(Int(p.start) - at)
            h.combine(Int(p.end - p.start))
            h.combine(u.separated[i])
            at = Int(p.start)
        }
        return Key(hash: h.finalize(), length: (text as NSString).length)
    }

    // MARK: language

    private func resolveLanguage(units: [PosUnit], ns: NSString) -> NLLanguage? {
        if let o = languageOverride { language = o; return o }
        let stale = language == nil || editedSinceLanguage > 1_000 || Date().timeIntervalSince(languageStamp) > 60
        if stale, !units.isEmpty {
            var sample = ""
            for u in units {
                sample += Self.joinedText(of: u, in: ns) + "\n"
                if sample.utf16.count > 2_000 { break }
            }
            let r = NLLanguageRecognizer()
            r.processString(sample)
            let found = r.dominantLanguage
            language = found ?? language ?? Self.fallbackLanguage
            languageStamp = Date()
            editedSinceLanguage = 0
        }
        return language ?? Self.fallbackLanguage
    }

    static var fallbackLanguage: NLLanguage {
        Locale.current.language.languageCode.map { NLLanguage($0.identifier) } ?? .english
    }

    private func languageIsSupported(_ lang: NLLanguage) -> Bool {
        if let s = supported[lang] { return s }
        let s = tagger.supports(lang)
        supported[lang] = s
        return s
    }

    // MARK: tagging (background)

    private func drain(language lang: NLLanguage) {
        var batch: [(Key, [Relative])] = []
        var lastPost = CFAbsoluteTimeGetCurrent()
        func post(final: Bool) {
            let items = batch
            batch = []
            lock.lock(); pendingStores += 1; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.store(items, final: final) }
        }
        while true {
            lock.lock()
            guard !work.isEmpty else {
                draining = false
                lock.unlock()
                post(final: true)
                return
            }
            let job = work.removeFirst()
            tagging += 1
            _invocations += 1
            lock.unlock()
            let words = tagger.tag(job.text, language: unitLanguage(job.text, document: lang))
            let tags = words.map { PosTag(range: Utf16Range(start: UInt32($0.range.location), end: UInt32(NSMaxRange($0.range))), class: $0.posClass) }
            let mapped = posMapTags(unit: job.unit, words: tags)
            let base = job.unit.range.start
            let relative = mapped.map { Relative(location: Int($0.range.start - base), length: Int($0.range.end - $0.range.start), posClass: $0.class) }
            lock.lock(); tagging -= 1; lock.unlock()
            batch.append((job.key, relative))
            // The nearest text is shown as soon as it is tagged; the rest follows in batches.
            let now = CFAbsoluteTimeGetCurrent()
            if batch.count == 1 && now - lastPost > 0.5 || now - lastPost > 0.03 {
                post(final: false)
                lastPost = now
            }
        }
    }

    /// A paragraph long enough to judge, recognized with confidence as another language the
    /// tagger knows, is tagged as that language: a French paragraph in an English document gets
    /// French parts of speech. Anything shorter or less certain is the document's language.
    /// Decided from the unit's text alone, so the cache (keyed by text and document language)
    /// stays exact. Runs on the tagging queue.
    static let unitLanguageMinimum = 100
    static let unitLanguageConfidence = 0.9
    private var supportedOnQueue: [NLLanguage: Bool] = [:]

    private func unitLanguage(_ text: String, document lang: NLLanguage) -> NLLanguage {
        guard languageOverride == nil, (text as NSString).length >= Self.unitLanguageMinimum else { return lang }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (found, p) = r.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              found != lang, p >= Self.unitLanguageConfidence else { return lang }
        let ok = supportedOnQueue[found] ?? tagger.supports(found)
        supportedOnQueue[found] = ok
        return ok ? found : lang
    }

    /// Results arrive: remember them, and look at the text again (it may have moved since).
    private func store(_ items: [(Key, [Relative])], final: Bool) {
        lock.lock(); pendingStores -= 1; lock.unlock()
        if cache.count + items.count > Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        for (k, v) in items { cache[k] = v }
        guard isEnabled, !items.isEmpty else { return }
        schedule(after: 0)
    }

    /// Spins the run loop until nothing is pending (tests, the harness).
    @discardableResult
    public func waitUntilSettled(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !isEnabled || isSettled { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return isSettled
    }

    // MARK: for tests

    var cachedUnits: Int { cache.count }
    public var colouredLanguageIsSupported: Bool { if case .unsupported = status { return false } else { return true } }
    public func forgetCache() { cache.removeAll() }
}
