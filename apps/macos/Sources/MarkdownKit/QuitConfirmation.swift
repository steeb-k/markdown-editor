import AppKit

/// "Quit Markdown?": asked when the app is told to quit with a document window open (⌘Q, Quit in the Dock's menu, logout
/// and shutdown all end in `applicationShouldTerminate`; `MarkdownApplication.terminate` asks a step earlier, before
/// AppKit goes through the documents, for the reason given there). The checkbox in it and the preference "Ask before
/// quitting" are one setting.
public enum QuitConfirmation {
    /// The question has been answered Quit for this quit (the delegate does not ask again).
    nonisolated(unsafe) public static var confirmed = false

    /// Shows the question and says what was chosen. Tests and the UI harness give their own, which answer without a panel.
    nonisolated(unsafe) public static var run: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// The question.
    public static func makeAlert(reopens: Bool = true) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit Markdown?"
        alert.informativeText = reopens ? "Your documents are saved; the windows reopen next time." : "Your documents are saved."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not ask again"
        return alert
    }

    /// Whether the app may quit: with no document window open at once, otherwise after the question (unless the
    /// preference says not to ask). "Do not ask again", ticked with Quit, turns the preference off.
    public static func mayQuit(windows: Int, settings: Settings) -> Bool {
        guard windows > 0, settings.askBeforeQuitting else { return true }
        let alert = makeAlert(reopens: settings.reopenAtLaunch)
        guard run(alert) == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { settings.askBeforeQuitting = false }
        return true
    }

    /// Everything before the app ends: the question, then the record of the windows (the last write), then the untitled
    /// documents are told that their text stays in the record: AppKit goes through the documents next, and an untitled one
    /// with text would be drafted into the library or asked about, when quitting never asks to save them. False when the
    /// person cancelled.
    public static func prepareToQuit(settings: Settings = .shared, windows: [EditorWindowController] = SessionRecorder.documentWindows()) -> Bool {
        guard mayQuit(windows: windows.count, settings: settings) else { return false }
        confirmed = true
        for wc in windows { wc.markdownDocument?.keepsTextOnQuit = wc.fileURL == nil }
        SessionRecorder.current?.writeNow(final: true)
        // A quit that does not go through (a save that failed and was cancelled in AppKit's own question) leaves the
        // app as it was; one that does is over long before this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { cancelQuit(windows: windows) }
        return true
    }

    /// The quit did not happen.
    static func cancelQuit(windows: [EditorWindowController]) {
        confirmed = false
        for wc in windows { wc.markdownDocument?.keepsTextOnQuit = false }
        SessionRecorder.current?.resume()
    }
}

/// The application: ⌘Q (and the Dock's Quit, which AppKit turns into the same call) asks "Quit Markdown?" and writes the
/// session record before AppKit reviews the documents. AppKit reviews them before it asks the delegate, and an untitled
/// document with text, with the system setting "Close windows when quitting" on, would meet its own question there.
public final class MarkdownApplication: NSApplication {
    public override func terminate(_ sender: Any?) {
        guard QuitConfirmation.confirmed || QuitConfirmation.prepareToQuit() else { return }
        super.terminate(sender)
    }
}
