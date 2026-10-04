import AppKit
import MarkdownCore

/// The outline column's side of a session: whether it is shown here, and the headings, asked of the core's
/// analysis queue a moment after the last answer to an edit, so typing never waits for them.
extension EditorSession {
    /// Showing the outline takes the column from the history, if that was in it.
    public func setOutlineShown(_ on: Bool) {
        guard on != outlineShown else { return }
        outlineShown = on
        if on { historyShown = false }
        if on { requestOutline() } else { outlineTimer?.invalidate(); outlineTimer = nil }
        onOutlineVisibilityChange?()
    }

    /// Showing the history takes the column from the outline, if that was in it.
    public func setHistoryShown(_ on: Bool) {
        guard on != historyShown else { return }
        historyShown = on
        if on, outlineShown {
            outlineShown = false
            outlineTimer?.invalidate()
            outlineTimer = nil
        }
        onHistoryVisibilityChange?()
    }

    /// An analysis answered: the headings may have changed. One timer, moved on by each answer.
    func scheduleOutline() {
        let due = Date(timeIntervalSinceNow: Self.outlineDelay)
        if let t = outlineTimer, t.isValid { t.fireDate = due; return }
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestOutline() }
        }
        RunLoop.main.add(t, forMode: .common)
        outlineTimer = t
    }

    /// Asks the queue for the headings now (after the edits it has, answered on the main thread). An answer for
    /// text the user has since typed in is dropped: the analysis that follows asks again.
    public func requestOutline() {
        outlineTimer?.invalidate()
        outlineTimer = nil
        guard outlineShown else { return }
        coordinator.async({ $0.outline() }) { [weak self] entries, seq in
            guard let self, outlineShown, seq == coordinator.latestSeq else { return }
            if entries != outlineEntries { outlineEntries = entries }
            onOutline?(entries)
        }
    }
}
