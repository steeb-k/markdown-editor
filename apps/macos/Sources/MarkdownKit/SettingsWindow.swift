import AppKit
import Combine
import SwiftUI

/// Re-publishes `Settings` changes to SwiftUI.
final class SettingsModel: ObservableObject {
    let settings: Settings
    private var token: NSObjectProtocol?

    /// What is typed in the search field. A query the shown pane has no match for moves the selection to the pane it
    /// names, or else to the first pane that has a match (a pane's name is mentioned in other panes' rows: "Notes" is in
    /// General's "Open new windows in Notes mode"); clearing it keeps the pane then shown.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            let found = panes
            if let first = found.first, !found.contains(pane) { pane = found.first { SettingsCatalog.names($0, query) } ?? first }
        }
    }

    /// The pane shown, remembered in the settings so the window opens where it was left.
    @Published var pane: SettingsPane {
        didSet { if pane != oldValue { settings.settingsPane = pane.rawValue } }
    }
    /// Whether the search field has the caret: SwiftUI's own binding, which holds against the sidebar's list taking the
    /// keyboard at its first layout (an AppKit first responder set before that is taken back).
    @Published var searchPresented = false

    /// The panes with a row that matches the query (all of them for an empty query), in the sidebar's order.
    var panes: [SettingsPane] { SettingsCatalog.panes(matching: query, settings: settings) }

    /// The rows of the shown pane that match the query.
    var rows: [SettingsRow] { SettingsCatalog.rows(in: pane, matching: query, settings: settings) }

    init(settings: Settings) {
        self.settings = settings
        pane = SettingsPane(rawValue: settings.settingsPane) ?? .general
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

/// A pane's icon in the sidebar: the symbol in white on a small rounded tile, as System Settings draws it.
private struct PaneTile: View {
    let pane: SettingsPane
    var body: some View {
        // System Settings' metrics: a 20-point tile, the symbol at 11 points, white, a small continuous corner.
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(pane.tint.gradient))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var templates: TemplateStore = .shared

    /// The shown rows with their section headers, in order; the section of a row follows the one before it.
    private var sections: [(title: String, rows: [SettingsRow])] {
        var out: [(title: String, rows: [SettingsRow])] = []
        for row in model.rows {
            if let last = out.last, last.title == row.section { out[out.count - 1].rows.append(row) } else { out.append((row.section, [row])) }
        }
        return out
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(model.panes, selection: Binding(get: { Optional(model.pane) }, set: { if let p = $0 { model.pane = p } })) { pane in
                Label { Text(pane.rawValue).padding(.leading, 2) } icon: { PaneTile(pane: pane) }
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if model.panes.isEmpty {
                    Text("No settings match “\(model.query)”")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        let context = SettingsContext(settings: model.settings, templates: templates)
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, group in
                            if group.title.isEmpty {
                                Section { rowViews(group.rows, context) }
                            } else {
                                Section(group.title) { rowViews(group.rows, context) }
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationSplitViewColumnWidth(520)
            .navigationTitle(model.pane.rawValue)
        }
        .searchable(text: $model.query, isPresented: $model.searchPresented, placement: .sidebar, prompt: "Search")
        .frame(width: 720, height: 640)
    }

    @ViewBuilder private func rowViews(_ rows: [SettingsRow], _ context: SettingsContext) -> some View {
        ForEach(rows) { $0.view(context) }
    }
}

public final class SettingsWindowController: NSWindowController {
    /// A UI script runs under the app's own bundle identifier, so its frames would land in the person's defaults: the
    /// harness's window keeps none.
    public static let shared = SettingsWindowController(settings: .shared, frameName: sharedFrameName)

    private static var sharedFrameName: String? {
        #if DEBUG || UI_SCRIPT
        if UIScriptRunner.isRequested { return nil }
        #endif
        return "MarkdownSettings"
    }

    let model: SettingsModel
    private var titleToken: AnyCancellable?
    private var searchToken: AnyCancellable?

    /// `frameName` is the name the window's frame is saved under in the standard defaults; nil (tests, a UI script) saves none.
    public init(settings: Settings, frameName: String? = nil) {
        model = SettingsModel(settings: settings)
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        // Not resizable: the content pane scrolls, so no pane needs a taller window. The sidebar runs the window's
        // full height under a transparent title bar, with the pane's name in a unified toolbar over the form, as
        // System Settings is laid out; without the toolbar the split view floats its sidebar inside the content.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "MarkdownSettingsToolbar")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 672))
        super.init(window: window)
        // Through the controller, not the window: a window controller hands its window its own autosave name when it
        // takes the window, which emptied the one set on the window before, so no frame was ever saved.
        if let frameName { windowFrameAutosaveName = frameName }
        // The title bar names the pane, as System Settings does.
        titleToken = model.$pane.sink { [weak window] pane in window?.title = pane.rawValue }
        // Escape in the field ends the search (SwiftUI drops the binding) and the list takes the keyboard, so the arrows
        // move the pane next: the field alone would keep the caret in a toolbar-style search.
        searchToken = model.$searchPresented.dropFirst().removeDuplicates().sink { [weak self] presented in
            guard !presented, let self, let window = self.window, (window.firstResponder as? NSTextView)?.isFieldEditor == true,
                  let list = Self.firstTable(in: window.contentView) else { return }
            window.makeFirstResponder(list)
        }
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        // Centred only the first time: after that the frame is where the person left it.
        if window?.isVisible != true, !hasSavedFrame { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private var hasSavedFrame: Bool {
        !windowFrameAutosaveName.isEmpty && UserDefaults.standard.string(forKey: "NSWindow Frame \(windowFrameAutosaveName)") != nil
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = firstTable(in: sub) { return t } }
        return nil
    }

    /// The search field of the window's sidebar, if SwiftUI has made it yet.
    var searchField: NSSearchField? {
        func find(_ v: NSView) -> NSSearchField? {
            if let f = v as? NSSearchField { return f }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        return window?.contentView.flatMap(find)
    }

    /// Puts the caret in the search field (Edit > Find while the window is key). As the window opens the sidebar's list
    /// takes the keyboard, as System Settings' does, whatever is asked before or after SwiftUI's first layout; the field
    /// is given it on request only, with a retry for a field SwiftUI has not built yet.
    func focusSearch(retries: Int = 10) {
        model.searchPresented = true
        guard let window else { return }
        if let field = searchField { window.makeFirstResponder(field); return }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusSearch(retries: retries - 1) }
    }

    /// Edit > Find while this window is key: the search field, not the editor's find bar.
    @objc public override func performTextFinderAction(_ sender: Any?) { focusSearch() }
}
