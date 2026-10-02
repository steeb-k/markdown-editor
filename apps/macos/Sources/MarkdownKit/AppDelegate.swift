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
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // NSDocumentController opens the untitled document (or the files we were launched with).
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG || UI_SCRIPT
        UIScriptRunner.startIfRequested()
        #endif
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        #if DEBUG || UI_SCRIPT
        if UIScriptRunner.isRequested { return false }
        #endif
        return true
    }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { !flag }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: actions (global settings)

    @objc public func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc public func toggleFormattingToolbar(_ sender: Any?) {
        Settings.shared.showFormattingToolbar.toggle()
    }

    @objc public func biggerText(_ sender: Any?) { Settings.shared.fontSize += 1 }
    @objc public func smallerText(_ sender: Any?) { Settings.shared.fontSize -= 1 }
    @objc public func actualSize(_ sender: Any?) { Settings.shared.fontSize = 17 }

    @objc public func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://commonmark.org/help/") { NSWorkspace.shared.open(url) }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFormattingToolbar(_:)):
            item.title = Settings.shared.showFormattingToolbar ? "Hide Formatting Toolbar" : "Show Formatting Toolbar"
            return true
        case #selector(biggerText(_:)): return Settings.shared.fontSize < Settings.fontSizeRange.upperBound
        case #selector(smallerText(_:)): return Settings.shared.fontSize > Settings.fontSizeRange.lowerBound
        default: return true
        }
    }
}
