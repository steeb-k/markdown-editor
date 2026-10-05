import AppKit
import SwiftUI

/// Re-publishes `Settings` changes to SwiftUI.
final class SettingsModel: ObservableObject {
    let settings: Settings
    private var token: NSObjectProtocol?
    init(settings: Settings) {
        self.settings = settings
        token = NotificationCenter.default.addObserver(forName: Settings.didChangeNotification, object: settings, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// Receives the font panel's choice for "Custom…" (only the family is taken; size is a setting).
final class FontPanelTarget: NSObject {
    static let shared = FontPanelTarget()
    var settings: Settings = .shared
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let family = sender?.convert(NSFont.systemFont(ofSize: 13)).familyName else { return }
        settings.customFontFamily = family
        settings.fontChoice = .custom
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    private var s: Settings { model.settings }

    var body: some View {
        Form {
            Toggle("Reopen documents at launch", isOn: Binding(get: { s.reopenAtLaunch }, set: { s.reopenAtLaunch = $0 }))
            Toggle("Ask before quitting", isOn: Binding(get: { s.askBeforeQuitting }, set: { s.askBeforeQuitting = $0 }))
            Picker("Theme", selection: Binding(get: { s.theme }, set: { s.theme = $0 })) {
                ForEach(ThemeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Font", selection: Binding(get: { s.fontChoice }, set: { s.fontChoice = $0 })) {
                ForEach(FontChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if s.fontChoice == .custom {
                HStack {
                    Picker("Family", selection: Binding(get: { s.customFontFamily }, set: { s.customFontFamily = $0 })) {
                        if s.customFontFamily.isEmpty { Text("Choose…").tag("") }
                        ForEach(FontStore.installedFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Font Panel…") {
                        FontPanelTarget.shared.settings = s
                        NSFontManager.shared.target = FontPanelTarget.shared
                        NSFontManager.shared.setSelectedFont(NSFont.systemFont(ofSize: 13), isMultiple: false)
                        NSFontManager.shared.orderFrontFontPanel(nil)
                    }
                }
            }
            if !FontStore.bundledFontsAvailable, [.iaMono, .iaDuo, .iaQuattro].contains(s.fontChoice) {
                Text("The bundled fonts were not found; a system font is used instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper(value: Binding(get: { s.fontSize }, set: { s.fontSize = $0 }), in: Settings.fontSizeRange, step: 1) {
                Text("Font size: \(Int(s.fontSize)) pt")
            }
            Stepper(value: Binding(get: { s.lineWidth }, set: { s.lineWidth = $0 }), in: Settings.lineWidthRange, step: 2) {
                Text("Line width: \(s.lineWidth) characters")
            }
            Picker("Default view", selection: Binding(get: { s.defaultViewMode }, set: { s.defaultViewMode = $0 })) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Default layout", selection: Binding(get: { s.defaultLayout }, set: { s.defaultLayout = $0 })) {
                ForEach(LayoutMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show side column in new windows", isOn: Binding(get: { s.showSideColumnInNewWindows }, set: { s.showSideColumnInNewWindows = $0 }))
            Picker("Side column starts on", selection: Binding(get: { s.sideColumnPane }, set: { s.sideColumnPane = $0 })) {
                ForEach(SideColumnPane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Start windows in focus mode", isOn: Binding(get: { s.focusMode }, set: { s.focusMode = $0 }))
            Picker("Focus on", selection: Binding(get: { s.focusScope }, set: { s.focusScope = $0 })) {
                ForEach(FocusScopeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Keep the focused line centred", isOn: Binding(get: { s.centreFocusedLine }, set: { s.centreFocusedLine = $0 }))
            Toggle("Start windows with syntax highlighting", isOn: Binding(get: { s.syntaxHighlight }, set: { s.syntaxHighlight = $0 }))
            ForEach(SyntaxClass.allCases, id: \.self) { c in
                Toggle("Highlight \(c.title.lowercased())", isOn: Binding(get: { s.syntaxClass(c) }, set: { s.setSyntaxClass(c, $0) }))
            }
            Toggle("Show authorship colours in new windows", isOn: Binding(get: { s.authorshipDisplay }, set: { s.authorshipDisplay = $0 }))
            TextField("Name for my text", text: Binding(get: { s.authorNameSetting }, set: { s.authorNameSetting = $0 }),
                      prompt: Text(s.authorName))
            Toggle("Open new windows in Notes mode", isOn: Binding(get: { s.notesModeByDefault }, set: { s.notesModeByDefault = $0 }))
            TextField("Daily notes folder", text: Binding(get: { s.dailyFolder }, set: { s.dailyFolder = $0 }), prompt: Text("Daily"))
            TextField("Daily note name", text: Binding(get: { s.dailyFormat }, set: { s.dailyFormat = $0 }), prompt: Text("YYYY-MM-DD"))
            TextField("Templates folder", text: Binding(get: { s.templatesFolder }, set: { s.templatesFolder = $0 }), prompt: Text("Templates"))
            Toggle("Check spelling while typing", isOn: Binding(get: { s.spellCheck }, set: { s.spellCheck = $0 }))
            Toggle("Show formatting toolbar", isOn: Binding(get: { s.showFormattingToolbar }, set: { s.showFormattingToolbar = $0 }))
            Toggle("Hide title bar and toolbar while typing", isOn: Binding(get: { s.autoHideChrome }, set: { s.autoHideChrome = $0 }))
            Toggle("Show them again after a pause in typing", isOn: Binding(get: { s.chromeReturnsAfterPause }, set: { s.chromeReturnsAfterPause = $0 }))
                .disabled(!s.autoHideChrome)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController(settings: .shared)

    public init(settings: Settings) {
        let host = NSHostingController(rootView: SettingsView(model: SettingsModel(settings: settings)))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MarkdownSettings")
        super.init(window: window)
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
