import AppKit
import QuartzCore

/// The arithmetic of centring, with no views in it.
enum FocusCentringMath {
    /// How much room focus mode adds above and below the text, so that the first and the last
    /// line can reach the middle: half of what the reader sees.
    static func extraInset(visibleHeight: CGFloat) -> CGFloat {
        max(0, (visibleHeight / 2).rounded(.up))
    }

    /// The clip view's origin that puts a line whose middle is `lineMidY` (in the text view's
    /// coordinates) at the vertical centre of the visible area. The visible area is the clip
    /// view's height less the permanent insets (`baseTop`: the title bar, and its own height
    /// `visibleHeight`); the answer is held within `range`, what the scroll view allows.
    static func targetOrigin(lineMidY: CGFloat, baseTop: CGFloat, visibleHeight: CGFloat,
                             range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(lineMidY - baseTop - visibleHeight / 2, range.lowerBound), range.upperBound)
    }

    /// What the scroll view allows for a text of `documentHeight` points: from the top of the
    /// text with the whole top inset above it, to its end with the whole bottom inset below.
    static func scrollRange(documentHeight: CGFloat, clipHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> ClosedRange<CGFloat> {
        let low = -topInset
        return low...max(low, documentHeight + bottomInset - clipHeight)
    }

    /// Ease in, ease out (cubic).
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// The editor's scroll view. It knows how much of its content inset is focus mode's (the rest is
/// the title bar and the formatting bar), and tells the centring when the user scrolls.
final class EditorScrollView: NSScrollView {
    /// Part of `contentInsets.top` and `.bottom` that focus mode added for centring.
    var focusInset: CGFloat = 0
    var onUserScroll: (() -> Void)?

    /// The inset under the title bar, without focus mode's.
    var baseInsetTop: CGFloat { contentInsets.top - focusInset }
    var baseInsetBottom: CGFloat { contentInsets.bottom - focusInset }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

extension NSScrollView {
    /// The inset under the title bar, whether or not focus mode has made room for centring.
    var editorBaseInsetTop: CGFloat { (self as? EditorScrollView)?.baseInsetTop ?? contentInsets.top }
}

/// Focus mode's vertical centring, typewriter style: the caret's line sits in the middle
/// of the visible area, slides there when focus mode starts (about 0.3 s) and follows the caret as
/// it moves (about 0.12 s, typewriter scrolling).
///
/// It never fights the user: a scroll in progress (wheel, trackpad, scroller) cancels the slide
/// and stops it until the next keystroke or caret move; nothing is centred while a mouse button
/// is down (a drag selection, a click); every request in one turn of the run loop, whether from
/// the selection or from `scrollRangeToVisible`, becomes one slide.
@MainActor
final class FocusCentring {
    static let enterDuration: TimeInterval = 0.3
    static let followDuration: TimeInterval = 0.12

    weak var scrollView: EditorScrollView?
    weak var textView: EditorTextView?
    weak var session: EditorSession?
    /// The window controller lays the insets out (they also depend on the title bar and the formatting bar).
    var applyInsets: () -> Void = {}
    /// Reduce Motion: jump instead of sliding.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The event being handled is the mouse's (a click or a drag selection places the caret; the line stays where it was clicked).
    var currentEventIsMouse: () -> Bool = {
        // (The event being handled, not one that was the last to arrive some while ago.)
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp: return true
        default: return false
        }
    }
    /// The editor is on screen (it is not in the Preview layout).
    var editorShown: () -> Bool = { true }
    /// Seconds, a steady clock (tests substitute their own).
    var now: () -> TimeInterval = { CACurrentMediaTime() }
    var enterDuration = FocusCentring.enterDuration
    var followDuration = FocusCentring.followDuration

    /// Centring is on: focus mode, the setting, and the room above and below the text.
    private(set) var isActive = false
    /// The room above and below the text is there (it outlasts focus mode by the slide that removes it).
    private(set) var holdsRoom = false
    /// The user scrolled; nothing is centred until the next keystroke or caret move.
    private(set) var userScrolling = false

    // Instrumentation.
    private(set) var timeOnMain: TimeInterval = 0
    private(set) var slides = 0
    private(set) var frames = 0
    private(set) var longestFrame: TimeInterval = 0
    private(set) var jumps = 0

    private struct Slide {
        var from: CGFloat, to: CGFloat
        var start: TimeInterval, duration: TimeInterval
        var onFinish: (() -> Void)?
    }
    private var slide: Slide?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var requestPending = false
    private var wanted: NSRange?
    /// The request came from the mouse: it is not centred.
    private var fromMouse = false
    /// The caret was last put where it is by the mouse (until the next keystroke or caret move).
    private(set) var caretPlacedByMouse = false
    /// Lines are laid out lazily, so where the caret's line is can change once the text above it is
    /// laid out (it was an estimate): a request is checked again a few times after it has settled.
    private var verifications = 0
    private static let verificationsPerRequest = 3
    private var observers: [NSObjectProtocol] = []

    var isSliding: Bool { slide != nil }
    /// Nothing is moving and nothing is waiting to (a slide, a request, a check of the result).
    var isSettled: Bool { slide == nil && !requestPending && verifyTimers == 0 }
    private var verifyTimers = 0

    init() {}

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Wires the user-scroll signals of `scroll` (wheel and trackpad events, scroller drags).
    func attach(to scroll: EditorScrollView) {
        scrollView = scroll
        scroll.onUserScroll = { [weak self] in MainActor.assumeIsolated { self?.userScrolled() } }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        })
    }

    // MARK: switching

    /// Focus mode, the setting or the layout changed: bring centring (and the room it needs) in line.
    func update() {
        let wanted = (session?.focusEnabled ?? false) && (session?.settings.centreFocusedLine ?? false)
        if wanted && !isActive {
            activate()
        } else if !wanted && isActive {
            deactivate()
        } else if wanted {
            // Still on: a resize or a changed bar moved the middle (the user's own scroll is left alone).
            applyInsets()
            if !userScrolling { centre(on: caretRange(), duration: 0) }
        }
    }

    private func activate() {
        guard let scroll = scrollView else { return }
        isActive = true
        userScrolling = false
        caretPlacedByMouse = false
        holdsRoom = true
        let origin = scroll.contentView.bounds.minY
        applyInsets()
        // The room appears without moving the text; then the caret's line slides to the middle.
        place(origin)
        centre(on: caretRange(), duration: reduceMotion() || !editorShown() ? 0 : enterDuration)
    }

    private func deactivate() {
        guard let scroll = scrollView else { isActive = false; holdsRoom = false; return }
        isActive = false
        cancelSlide()
        requestPending = false
        wanted = nil
        let clip = scroll.contentView
        let current = clip.bounds.minY
        // Where the text may rest without the room: the same place unless that is out of range.
        let range = FocusCentringMath.scrollRange(documentHeight: documentHeight, clipHeight: clip.bounds.height,
                                                  topInset: scroll.baseInsetTop, bottomInset: scroll.baseInsetBottom)
        let target = min(max(current, range.lowerBound), range.upperBound)
        let finish = { [weak self] in
            guard let self else { return }
            holdsRoom = false
            let origin = scrollView?.contentView.bounds.minY ?? 0
            applyInsets()
            place(origin)
        }
        if abs(target - current) < 0.5 || reduceMotion() || !editorShown() {
            if abs(target - current) >= 0.5 { place(target) }
            finish()
        } else {
            start(Slide(from: current, to: target, start: now(), duration: enterDuration, onFinish: finish))
        }
    }

    /// The room focus mode adds, for the visible height the title bar and the formatting bar leave.
    func insetNow(visibleHeight: CGFloat) -> CGFloat {
        holdsRoom ? FocusCentringMath.extraInset(visibleHeight: visibleHeight) : 0
    }

    // MARK: requests

    /// The caret moved or the text changed (`user`: from the keyboard or the selection, which
    /// ends a user scroll's hold), or something asked for `range` to be shown.
    func request(_ range: NSRange? = nil, user: Bool = true) {
        guard isActive else { return }
        let mouse = currentEventIsMouse()
        if user {
            userScrolling = false
            caretPlacedByMouse = mouse
        }
        if mouse { fromMouse = true }
        wanted = range ?? wanted ?? caretRange()
        verifications = Self.verificationsPerRequest
        guard !requestPending else { return }
        requestPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// The text re-laid out (concealment changed, a picture arrived): keep the middle, unless the user
    /// is scrolling or put the caret where it is with the mouse. (The focus range and Live mode's
    /// concealment for a click arrive after the click when the analysis queue is busy, out of any
    /// mouse event: they must not slide the clicked line away.)
    func layoutChanged() {
        guard isActive, !userScrolling, !caretPlacedByMouse else { return }
        request(nil, user: false)
    }

    private func flush() {
        requestPending = false
        let range = wanted
        wanted = nil
        let mouse = fromMouse
        fromMouse = false
        guard isActive, !userScrolling, let range else { return }
        // A drag selection or a click is the user's: the line stays where it was clicked.
        // A newer request makes the checks of the older ones moot (they would bring back a line
        // the caret has left: during key repeat, a slide back and forth).
        requestGeneration += 1
        if mouse { verifications = 0; return }
        centre(on: range, duration: reduceMotion() || !editorShown() ? 0 : followDuration)
        verifySoon(range)
    }

    private var requestGeneration = 0

    /// Once the slide (or jump) is over and the text has been laid out and drawn, is the line still in the middle?
    private func verifySoon(_ range: NSRange) {
        guard verifications > 0 else { return }
        verifications -= 1
        let delay = (slide.map { max(0, $0.start + $0.duration - now()) } ?? 0) + 0.03
        verifyTimers += 1
        let generation = requestGeneration
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.verifyTimers -= 1
                if generation == self.requestGeneration { self.verify(range) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func verify(_ range: NSRange) {
        guard isActive, !userScrolling, !requestPending, !fromMouse else { return }
        guard let target = targetOrigin(for: range), let clip = scrollView?.contentView else { return }
        if slide == nil, abs(clip.bounds.minY - target) >= 0.5 {
            centre(on: range, duration: reduceMotion() || !editorShown() ? 0 : followDuration)
        }
        verifySoon(range)
    }

    /// The user is scrolling (wheel, trackpad, scroller): the slide stops and nothing is centred
    /// until the next keystroke or caret move.
    func userScrolled() {
        guard isActive else { return }
        userScrolling = true
        requestPending = false
        wanted = nil
        cancelSlide()
    }

    // MARK: geometry

    private func caretRange() -> NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    private var documentHeight: CGFloat { textView?.frame.height ?? 0 }

    /// The middle of the caret's line in the text view's coordinates.
    func lineMidY(at location: Int) -> CGFloat? {
        guard let tv = textView, let session, let tc = tv.textContainer else { return nil }
        let lm = session.layoutManager
        let length = session.storage.length
        let originY = tv.textContainerOrigin.y
        var mid: CGFloat
        /// The empty line after a final newline (or an empty text): the layout manager has only the
        /// room for it, the caret is as tall as the font and sits at its top.
        func extraLineMid() -> CGFloat? {
            let extra = lm.extraLineFragmentRect
            guard !extra.isEmpty else { return nil }
            let font = (tv.typingAttributes[.font] as? NSFont) ?? session.appearance.fonts.body
            return extra.minY + lm.defaultLineHeight(for: font) / 2
        }
        if length == 0 {
            lm.ensureLayout(for: tc)
            guard let m = extraLineMid() else { return nil }
            mid = m
        } else if location >= length {
            // From the start: with non-contiguous layout the lines above are estimates until laid
            // out, and the middle of an estimate is not the middle of the line (the restore of the
            // editor's top does the same). Once laid out, this costs nothing more.
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
            if let m = extraLineMid() {
                mid = m
            } else {
                mid = lm.lineFragmentUsedRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil).midY
            }
        } else {
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: location + 1))
            let glyph = lm.glyphIndexForCharacter(at: location)
            mid = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).midY
        }
        return mid + originY
    }

    /// The origin the clip view should have for the line holding `range`, or nil when it cannot be told.
    func targetOrigin(for range: NSRange) -> CGFloat? {
        guard let scroll = scrollView, let mid = lineMidY(at: range.location) else { return nil }
        let clip = scroll.contentView
        let baseTop = scroll.baseInsetTop, baseBottom = scroll.baseInsetBottom
        let visible = clip.bounds.height - baseTop - baseBottom
        let allowed = FocusCentringMath.scrollRange(documentHeight: documentHeight, clipHeight: clip.bounds.height,
                                                    topInset: scroll.contentInsets.top, bottomInset: scroll.contentInsets.bottom)
        return FocusCentringMath.targetOrigin(lineMidY: mid, baseTop: baseTop, visibleHeight: visible, range: allowed)
    }

    private func centre(on range: NSRange, duration: TimeInterval) {
        guard isActive, let scroll = scrollView else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeOnMain += CFAbsoluteTimeGetCurrent() - t0 }
        guard let target = targetOrigin(for: range) else { return }
        let current = scroll.contentView.bounds.minY
        if let slide, abs(slide.to - target) < 0.5 { return }
        if abs(current - target) < 0.5 { cancelSlide(); return }
        if duration <= 0 {
            cancelSlide()
            jumps += 1
            place(target)
        } else {
            slides += 1
            start(Slide(from: current, to: target, start: now(), duration: duration, onFinish: nil))
        }
    }

    private func place(_ y: CGFloat) {
        guard let scroll = scrollView else { return }
        let clip = scroll.contentView
        guard abs(clip.bounds.minY - y) >= 0.01 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: sliding

    /// Frames are delivered (tests switch them off to show that a slide still ends without any).
    var deliversFrames = true

    private func start(_ new: Slide) {
        cancelSlide()
        slide = new
        if deliversFrames {
            if let clip = scrollView?.contentView, let window = clip.window, window.isVisible, window.occlusionState.contains(.visible) {
                let l = clip.displayLink(target: self, selector: #selector(displayTick(_:)))
                l.add(to: .main, forMode: .common)
                link = l
            } else {
                let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        }
        // A display link sends no frames while the display sleeps (and may send none for a window
        // that is covered): the slide still ends where it was going, on time, so the line and the
        // room it needs are never left half way.
        let deadline = Timer(timeInterval: new.duration + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deadlineTimer = nil
                self?.tick()
            }
        }
        RunLoop.main.add(deadline, forMode: .common)
        deadlineTimer = deadline
    }

    private var deadlineTimer: Timer?

    private func cancelSlide() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
        deadlineTimer?.invalidate(); deadlineTimer = nil
        slide = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) { tick() }

    /// One frame of the slide at the time `now()` says (the display link's, the timer's, or a test's).
    func tick() {
        guard let s = slide else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let progress = (now() - s.start) / s.duration
        if progress >= 1 {
            cancelSlide()
            place(s.to)
            s.onFinish?()
        } else {
            place(s.from + (s.to - s.from) * CGFloat(FocusCentringMath.ease(progress)))
        }
        let d = CFAbsoluteTimeGetCurrent() - t0
        timeOnMain += d
        frames += 1
        longestFrame = max(longestFrame, d)
    }
}
