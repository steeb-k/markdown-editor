import AppKit
import MarkdownCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let window = Self.makeWindow()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Initial text goes through the Rust core, proving the FFI works at runtime.
    public static func initialText() -> String {
        let doc = Document(text: "# Markdown\n\nCore \(coreVersion()) is alive. 🎉\n")
        return doc.text()
    }

    static func makeWindow() -> NSWindow {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.string = initialText()
            tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            tv.isRichText = false
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.textContainerInset = NSSize(width: 16, height: 16)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markdown"
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
