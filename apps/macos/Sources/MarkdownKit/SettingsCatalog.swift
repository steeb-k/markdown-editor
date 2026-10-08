import AppKit
import SwiftUI

/// The panes of the Settings window, in the order of its sidebar. The raw value is the name shown and the one remembered.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", editor = "Editor", checking = "Checking"
    case authorship = "Authorship", notes = "Notes", documents = "Documents"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .editor: "text.cursor"
        case .checking: "textformat.abc.dottedunderline"
        case .authorship: "person.text.rectangle"
        case .notes: "note.text"
        case .documents: "doc.richtext"
        }
    }

    /// The colour of the pane's tile in the sidebar.
    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .blue
        case .editor: .indigo
        case .checking: .red
        case .authorship: .orange
        case .notes: .yellow
        case .documents: .green
        }
    }
}

/// What a row's view needs: the settings it edits and the template list its picker offers.
struct SettingsContext {
    let settings: Settings
    let templates: TemplateStore
}

/// One row of the Settings window, declared once: the panes show their rows from the table and the search reads the same
/// table, so a row cannot be in one and not the other.
struct SettingsRow: Identifiable {
    let pane: SettingsPane
    /// The section header inside the pane; empty for a pane (or a row) without one.
    let section: String
    let title: String
    /// Words a person would type for this row that its title does not contain.
    let keywords: [String]
    /// The stored keys the row edits (`Settings.Key`); none for a button or a note. The completeness test reads these.
    let keys: [String]
    /// Whether the row is shown at all now (the family picker only for a custom font).
    var when: (Settings) -> Bool = { _ in true }
    let view: (SettingsContext) -> AnyView

    var id: String { pane.rawValue + "/" + title }
}

extension Settings {
    /// A binding to one property, so every row keeps the control and the setter it always had.
    fileprivate func bind<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

enum SettingsCatalog {
    /// Every row, in the order the panes show them. `AnyView` is the price of one table for different controls; this is a
    /// settings form, not a hot path.
    static let rows: [SettingsRow] = general + appearance + editor + checking + authorship + notes + documents

    private static func toggle(_ title: String, _ pane: SettingsPane, _ section: String, _ keys: [String], _ keywords: [String],
                               _ path: ReferenceWritableKeyPath<Settings, Bool>, disabledWhen: ((Settings) -> Bool)? = nil) -> SettingsRow {
        SettingsRow(pane: pane, section: section, title: title, keywords: keywords, keys: keys) { c in
            AnyView(Toggle(title, isOn: c.settings.bind(path)).disabled(disabledWhen?(c.settings) ?? false))
        }
    }

    private static let general: [SettingsRow] = [
        toggle("Reopen documents at launch", .general, "Windows", [Settings.Key.reopenAtLaunch], ["restore", "startup", "relaunch"], \.reopenAtLaunch),
        toggle("Ask before quitting", .general, "Windows", [Settings.Key.askBeforeQuitting], ["quit", "exit", "confirm"], \.askBeforeQuitting),
        toggle("Open new windows in Notes mode", .general, "Windows", [Settings.Key.notesMode], ["library", "sidebar", "folder"], \.notesModeByDefault),
        SettingsRow(pane: .general, section: "Layout", title: "Default layout", keywords: ["split", "preview", "view", "single"], keys: [Settings.Key.defaultLayout]) { c in
            AnyView(Picker("Default layout", selection: c.settings.bind(\.defaultLayout)) {
                ForEach(LayoutMode.allCases, id: \.self) { Text($0.title).tag($0) }
            })
        },
        toggle("Show side column in new windows", .general, "Layout", [Settings.Key.sideColumnByDefault], ["outline", "history", "panel"], \.showSideColumnInNewWindows),
        SettingsRow(pane: .general, section: "Layout", title: "Side column starts on", keywords: ["outline", "history", "panel"], keys: [Settings.Key.sideColumnPane]) { c in
            AnyView(Picker("Side column starts on", selection: c.settings.bind(\.sideColumnPane)) {
                ForEach(SideColumnPane.allCases, id: \.self) { Text($0.title).tag($0) }
            })
        },
    ]

    private static let appearance: [SettingsRow] = [
        SettingsRow(pane: .appearance, section: "", title: "Theme", keywords: ["dark", "light", "colour", "colors", "color", "mode"], keys: [Settings.Key.theme]) { c in
            AnyView(Picker("Theme", selection: c.settings.bind(\.theme)) {
                ForEach(ThemeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            })
        },
        SettingsRow(pane: .appearance, section: "Type", title: "Font", keywords: ["typeface", "family", "mono", "serif"], keys: [Settings.Key.font]) { c in
            AnyView(Picker("Font", selection: c.settings.bind(\.fontChoice)) {
                ForEach(FontChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            })
        },
        SettingsRow(pane: .appearance, section: "Type", title: "Family", keywords: ["font", "typeface", "custom", "panel"], keys: [Settings.Key.customFamily],
                    when: { $0.fontChoice == .custom }) { c in
            let s = c.settings
            return AnyView(HStack {
                Picker("Family", selection: s.bind(\.customFontFamily)) {
                    if s.customFontFamily.isEmpty { Text("Choose…").tag("") }
                    ForEach(FontStore.installedFamilies, id: \.self) { Text($0) }
                }
                Button("Font Panel…") {
                    FontPanelTarget.shared.settings = s
                    NSFontManager.shared.target = FontPanelTarget.shared
                    NSFontManager.shared.setSelectedFont(NSFont.systemFont(ofSize: 13), isMultiple: false)
                    NSFontManager.shared.orderFrontFontPanel(nil)
                }
            })
        },
        SettingsRow(pane: .appearance, section: "Type", title: "Bundled fonts", keywords: ["missing", "not found"], keys: [],
                    when: { !FontStore.bundledFontsAvailable && [.iaMono, .iaDuo, .iaQuattro].contains($0.fontChoice) }) { _ in
            AnyView(Text("The bundled fonts were not found; a system font is used instead.").font(.caption).foregroundStyle(.secondary))
        },
        SettingsRow(pane: .appearance, section: "Type", title: "Font size", keywords: ["bigger", "larger", "smaller", "points", "pt", "zoom"], keys: [Settings.Key.fontSize]) { c in
            let s = c.settings
            return AnyView(Stepper(value: s.bind(\.fontSize), in: Settings.fontSizeRange, step: 1) { Text("Font size: \(Int(s.fontSize)) pt") })
        },
        SettingsRow(pane: .appearance, section: "Type", title: "Line width", keywords: ["measure", "column", "width", "characters", "margin"], keys: [Settings.Key.lineWidth]) { c in
            let s = c.settings
            return AnyView(Stepper(value: s.bind(\.lineWidth), in: Settings.lineWidthRange, step: 2) { Text("Line width: \(s.lineWidth) characters") })
        },
    ]

    private static let editor: [SettingsRow] = {
        var rows = [
            toggle("Start windows in focus mode", .editor, "Focus", [Settings.Key.focusMode], ["typewriter", "dim", "zen"], \.focusMode),
            SettingsRow(pane: .editor, section: "Focus", title: "Focus on", keywords: ["sentence", "paragraph", "dim", "scope"], keys: [Settings.Key.focusScope]) { c in
                AnyView(Picker("Focus on", selection: c.settings.bind(\.focusScope)) {
                    ForEach(FocusScopeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                })
            },
            toggle("Keep the focused line centred", .editor, "Focus", [Settings.Key.centreFocus], ["center", "centered", "typewriter", "scroll"], \.centreFocusedLine),
            toggle("Start windows with syntax highlighting", .editor, "Highlighting", [Settings.Key.syntaxHighlight], ["parts of speech", "grammar", "colour", "color"], \.syntaxHighlight),
        ]
        for c in SyntaxClass.allCases {
            rows.append(SettingsRow(pane: .editor, section: "Highlighting", title: "Highlight \(c.title.lowercased())", keywords: ["syntax", "parts of speech"],
                                    keys: [Settings.Key.syntaxClass(c)]) { ctx in
                AnyView(Toggle("Highlight \(c.title.lowercased())", isOn: Binding(get: { ctx.settings.syntaxClass(c) }, set: { ctx.settings.setSyntaxClass(c, $0) })))
            })
        }
        rows += [
            toggle("Show formatting toolbar", .editor, "Chrome", [Settings.Key.showToolbar], ["buttons", "bold", "italic"], \.showFormattingToolbar),
            toggle("Hide title bar and toolbar while typing", .editor, "Chrome", [Settings.Key.autoHide], ["chrome", "distraction", "fade"], \.autoHideChrome),
            toggle("Show them again after a pause in typing", .editor, "Chrome", [Settings.Key.chromeReturns], ["chrome", "return", "fade"], \.chromeReturnsAfterPause,
                   disabledWhen: { !$0.autoHideChrome }),
        ]
        return rows
    }()

    private static let checking: [SettingsRow] = [
        toggle("Check spelling while typing", .checking, "", [Settings.Key.spellCheck], ["spell", "spelling", "typos", "red", "underline"], \.spellCheck),
        toggle("Check grammar", .checking, "", [Settings.Key.grammarCheck], ["green", "underline", "sentences"], \.grammarCheck),
        toggle("Correct spelling automatically", .checking, "", [Settings.Key.autoCorrect], ["spell", "spelling", "typos", "autocorrect", "replace"], \.autoCorrect),
    ]

    private static let authorship: [SettingsRow] = [
        SettingsRow(pane: .authorship, section: "", title: "Name for my text", keywords: ["author", "me", "who", "byline"], keys: [Settings.Key.authorName]) { c in
            AnyView(TextField("Name for my text", text: c.settings.bind(\.authorNameSetting), prompt: Text(c.settings.authorName)))
        },
        toggle("Show authorship colours in new windows", .authorship, "", [Settings.Key.authorshipDisplay], ["colors", "color", "who wrote", "paste"], \.authorshipDisplay),
    ]

    private static let notes: [SettingsRow] = [
        SettingsRow(pane: .notes, section: "", title: "Daily notes folder", keywords: ["journal", "today", "directory"], keys: [Settings.Key.dailyFolder]) { c in
            AnyView(TextField("Daily notes folder", text: c.settings.bind(\.dailyFolder), prompt: Text("Daily")))
        },
        SettingsRow(pane: .notes, section: "", title: "Daily note name", keywords: ["journal", "today", "date", "format", "file name"], keys: [Settings.Key.dailyFormat]) { c in
            AnyView(TextField("Daily note name", text: c.settings.bind(\.dailyFormat), prompt: Text("YYYY-MM-DD")))
        },
        SettingsRow(pane: .notes, section: "", title: "Note templates folder", keywords: ["templates", "directory"], keys: [Settings.Key.templatesFolder]) { c in
            AnyView(TextField("Note templates folder", text: c.settings.bind(\.templatesFolder), prompt: Text("Templates")))
        },
    ]

    private static let documents: [SettingsRow] = [
        SettingsRow(pane: .documents, section: "Look", title: "Default template", keywords: ["style", "css", "theme", "look", "preview"], keys: [Settings.Key.defaultTemplate]) { c in
            let s = c.settings, templates = c.templates
            // (The installed spelling: names match in any case, the popup's tags only exactly, so a default written
            // `academic`, or one renamed in capitals only, showed nothing chosen.)
            return AnyView(Picker("Default template", selection: Binding(get: { templates.template(named: s.defaultTemplate)?.name ?? s.defaultTemplate },
                                                                       set: { s.defaultTemplate = $0 })) {
                // A default that is no longer installed stays in the list, so the picker does not lie about it.
                if !templates.usable.contains(where: { TemplateStore.key($0.name) == TemplateStore.key(s.defaultTemplate) }) {
                    Text("\(s.defaultTemplate) (not installed)").tag(s.defaultTemplate)
                }
                ForEach(templates.usable) { Text($0.name).tag($0.name) }
            })
        },
        SettingsRow(pane: .documents, section: "Look", title: "Open Templates Window…", keywords: ["manage", "edit", "styles", "templates"], keys: []) { _ in
            AnyView(Button("Open Templates Window…") { TemplatesWindowController.shared.show() })
        },
        toggle("Keep front matter when exporting Markdown", .documents, "Export", [Settings.Key.exportKeepsFrontMatter], ["yaml", "metadata", "header"], \.exportKeepsFrontMatter),
    ]

    // MARK: search

    /// Case- and diacritic-insensitive, as a person types.
    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Whether the row answers the query: every word typed is found in its title, section, pane or keywords.
    static func matches(_ row: SettingsRow, _ query: String) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return true }
        let hay = fold(([row.title, row.section, row.pane.rawValue] + row.keywords).joined(separator: " "))
        return words.allSatisfy { hay.contains($0) }
    }

    /// Whether the query names the pane: every word typed is in its name.
    static func names(_ pane: SettingsPane, _ query: String) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { fold(pane.rawValue).contains($0) }
    }

    /// The rows now shown for a pane: the declared ones that apply to the settings and answer the query.
    static func rows(in pane: SettingsPane, matching query: String, settings: Settings) -> [SettingsRow] {
        rows.filter { $0.pane == pane && $0.when(settings) && matches($0, query) }
    }

    /// The panes with at least one such row, in the sidebar's order.
    static func panes(matching query: String, settings: Settings) -> [SettingsPane] {
        SettingsPane.allCases.filter { !rows(in: $0, matching: query, settings: settings).isEmpty }
    }
}
