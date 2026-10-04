import AppKit
import MarkdownCore

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public override init() { super.init() }

    /// Text that goes through the Rust core, proving the FFI works at runtime.
    public static func initialText() -> String {
        let doc = Document(text: "# Markdown\n\nCore \(coreVersion()) is alive. 🎉\n")
        return doc.text()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        FontStore.registerBundledFonts()
        // The menu has its own Enter Full Screen (with Control-Command-F); AppKit would add a second one.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // NSDocumentController opens the untitled document (or the files we were launched with).
        #if DEBUG || UI_SCRIPT
        // A UI script takes activation (and the person's keyboard) only if it has steps that need it: real mouse events.
        if !UIScriptRunner.isRequested || UIScriptRunner.scriptNeedsActivation { NSApp.activate(ignoringOtherApps: true) }
        UIScriptRunner.startIfRequested()
        #else
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        #if DEBUG || UI_SCRIPT
        if UIScriptRunner.isRequested { return false }
        #endif
        return true
    }
    /// A click on the Dock icon with no document window shows one (an untitled document), even
    /// when only the Settings window is open.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag, NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
            return false
        }
        return !flag
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: actions (global settings)

    @objc public func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc public func toggleFormattingToolbar(_ sender: Any?) {
        Settings.shared.showFormattingToolbar.toggle()
    }

    /// View > Keep Focused Line Centred: whether focus mode centres the caret's line (every window).
    @objc public func toggleCentreFocusedLine(_ sender: Any?) {
        Settings.shared.centreFocusedLine.toggle()
    }

    @objc public func biggerText(_ sender: Any?) { Settings.shared.fontSize += 1 }
    @objc public func smallerText(_ sender: Any?) { Settings.shared.fontSize -= 1 }
    @objc public func actualSize(_ sender: Any?) { Settings.shared.fontSize = 17 }

    /// The CommonMark reference, on the web.
    @objc public func openSyntaxReference(_ sender: Any?) {
        if let url = URL(string: "https://commonmark.org/help/") { NSWorkspace.shared.open(url) }
    }

    /// Help > Markdown Help: the bundled guide as a new, untitled document (so the guide is itself
    /// an example of the editor), with its table of shortcuts read from the menus as they are now.
    @objc public func showWelcome(_ sender: Any?) {
        guard let template = HelpDocuments.resource("Welcome", extension: "md") else { NSSound.beep(); return }
        let text = HelpDocuments.welcomeText(template: template, menu: NSApp.mainMenu ?? MainMenu.build())
        Self.openBundledDocument(named: "Markdown Help", text: text, mode: .live)
    }

    /// Help > Acknowledgements: the third-party notices, as an untitled document.
    @objc public func showAcknowledgements(_ sender: Any?) {
        guard let text = HelpDocuments.resource("Acknowledgements", extension: "md") else { NSSound.beep(); return }
        Self.openBundledDocument(named: "Acknowledgements", text: text, mode: .source)
    }

    /// Opens `text` as a new untitled document called `name`. Nothing is written anywhere and
    /// closing it asks nothing until it is edited.
    @discardableResult
    static func openBundledDocument(named name: String, text: String, mode: ViewMode) -> MarkdownDocument? {
        let controller = NSDocumentController.shared
        guard let doc = try? controller.makeUntitledDocument(ofType: controller.defaultType ?? "net.daringfireball.markdown") as? MarkdownDocument else { return nil }
        doc.isBundled = true
        doc.session.load(text)
        doc.session.setViewMode(mode)
        doc.displayName = name
        controller.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        // The text view exists now: Live mode asks the core what to conceal, and nothing the
        // document did to itself while loading counts as an edit.
        doc.session.refreshLive(force: true)
        doc.updateChangeCount(.changeCleared)
        // (Styling that follows the window's first layout can register as an edit: cleared again once it has run.)
        for delay in [0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak doc] in
                guard let doc, doc.fileURL == nil, doc.undoManager?.canUndo != true || doc.session.text == text else { return }
                doc.updateChangeCount(.changeCleared)
            }
        }
        return doc
    }

    /// The standard About panel (name, icon, version and build, copyright from Info.plist) with
    /// a line of credits.
    @objc public func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Built on a Rust core. The writing fonts are the bundled Mono, Duo and Quattro faces (SIL Open Font License). Open Help \u{25B8} Acknowledgements for every component and its license.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The layout of the window in front (the key window, else the front-most document window).
    static var frontLayout: LayoutMode? {
        let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { $0.windowController is EditorWindowController }
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.windowController is EditorWindowController }
        return (window?.windowController as? EditorWindowController)?.session.layout
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFormattingToolbar(_:)):
            item.title = Settings.shared.showFormattingToolbar ? "Hide Formatting Toolbar" : "Show Formatting Toolbar"
            return true
        case #selector(toggleCentreFocusedLine(_:)):
            item.state = Settings.shared.centreFocusedLine ? .on : .off
            // Centring is for the Editor layout: beside the preview the scroll sync needs the text where it is.
            let split = Self.frontLayout == .split
            item.toolTip = split ? "Applies to the Editor layout: beside the preview the line stays where it is and focus mode only dims."
                                 : "Focus mode keeps the line you are writing in the middle of the window."
            return !split
        case #selector(showWelcome(_:)): return HelpDocuments.resource("Welcome", extension: "md") != nil
        case #selector(showAcknowledgements(_:)): return HelpDocuments.resource("Acknowledgements", extension: "md") != nil
        case #selector(biggerText(_:)): return Settings.shared.fontSize < Settings.fontSizeRange.upperBound
        case #selector(smallerText(_:)): return Settings.shared.fontSize > Settings.fontSizeRange.lowerBound
        default: return true
        }
    }
}
