import AppKit
import MarkdownCore

/// The side column's side of a session: whether it is shown here, which pane, and the headings, asked of the core's
/// analysis queue a moment after the last answer to an edit, so typing never waits for them.
extension EditorSession {
    /// View > Side Column: the column shown or hidden, with the pane it last showed in this window.
    public func setColumnShown(_ on: Bool) {
        guard on != columnShown else { return }
        let before = outlineShown
        columnShown = on
        columnChanged(outlineWasShown: before)
    }

    /// The header's segment, or a menu, or a setting: the column shows `pane` (and is shown, if it was not). A click on
    /// a segment (`remember`) is also the default for windows opened later; ⌃⌘H and the other menu paths leave the
    /// setting ("Side column starts on") as the person set it.
    public func selectColumnPane(_ pane: SideColumnPane, remember: Bool = false) {
        let before = outlineShown
        if remember, settings.sideColumnPane != pane { settings.sideColumnPane = pane }
        guard pane != columnPane || !columnShown else { return }
        columnPane = pane
        columnShown = true
        columnChanged(outlineWasShown: before)
    }

    /// View > Show History: the column with History selected; when it is already showing it, hides the column
    /// (the same key shows and hides, as View > Side Column's does).
    public func toggleHistory() {
        if historyShown { setColumnShown(false) } else { selectColumnPane(.history) }
    }

    /// The outline in the column, shown or not (what the first M8d window setting and the tests ask for).
    public func setOutlineShown(_ on: Bool) {
        if on { selectColumnPane(.outline) } else if outlineShown { setColumnShown(false) }
    }

    /// The history in the column, shown or not.
    public func setHistoryShown(_ on: Bool) {
        if on { selectColumnPane(.history) } else if historyShown { setColumnShown(false) }
    }

    private func columnChanged(outlineWasShown: Bool) {
        if outlineShown { requestOutline() } else if outlineWasShown { outlineTimer?.invalidate(); outlineTimer = nil }
        onColumnChange?()
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
