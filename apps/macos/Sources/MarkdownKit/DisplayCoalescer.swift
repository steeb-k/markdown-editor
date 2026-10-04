import AppKit
import QuartzCore

/// Runs an action once at the next display refresh however many times it is asked for before then: a wheel event, or a
/// trackpad's stream of them, asks at every event and the work is done once a frame. A window nobody can see (ordered
/// out, covered, the display asleep) gets no frames, so a timer a frame and a half long stands in for the display's.
@MainActor
final class DisplayCoalescer: NSObject {
    private weak var view: NSView?
    private let action: () -> Void
    private var link: CADisplayLink?
    private var timer: Timer?
    private(set) var pending = false
    /// Instrumentation: how often it was asked, and how often it ran.
    private(set) var requests = 0
    private(set) var runs = 0

    init(view: NSView, action: @escaping () -> Void) {
        self.view = view
        self.action = action
        super.init()
    }

    func request() {
        requests += 1
        guard !pending else { return }
        pending = true
        if let view, let window = view.window, window.isVisible, window.occlusionState.contains(.visible) {
            let l = view.displayLink(target: self, selector: #selector(frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        let t = Timer(timeInterval: 1.0 / 40.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func frame(_ link: CADisplayLink) { fire() }

    private func fire() {
        guard pending else { return }
        cancel()
        runs += 1
        action()
    }

    func cancel() {
        pending = false
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    deinit {
        MainActor.assumeIsolated {
            link?.invalidate()
            timer?.invalidate()
        }
    }
}
