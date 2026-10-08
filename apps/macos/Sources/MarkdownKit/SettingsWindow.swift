import AppKit
import Combine
import SwiftUI

/// Re-publishes `Settings` changes to SwiftUI.
final class SettingsModel: ObservableObject {
    let settings: Settings
    private var token: NSObjectProtocol?

    /// What is typed in the search field. A query the shown pane has no match for moves the selection to the first pane
    /// that has one; clearing it keeps the pane then shown.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            let found = panes
            if let first = found.first, !found.contains(pane) { pane = first }
        }
    }

    /// The pane shown, remembered in the settings so the window opens where it was left.
    @Published var pane: SettingsPane {
        didSet { if pane != oldValue { settings.settingsPane = pane.rawValue } }
    }

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
        Image(systemName: pane.symbol)
            .resizable()
            .scaledToFit()
            .padding(4)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
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
                Label { Text(pane.rawValue) } icon: { PaneTile(pane: pane) }
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
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search")
        .frame(width: 720, height: 528)
    }

    @ViewBuilder private func rowViews(_ rows: [SettingsRow], _ context: SettingsContext) -> some View {
        ForEach(rows) { $0.view(context) }
    }
}

public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController(settings: .shared)

    let model: SettingsModel
    private var titleToken: AnyCancellable?

    public init(settings: Settings) {
        model = SettingsModel(settings: settings)
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        // Not resizable: the content pane scrolls, so no pane needs a taller window.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 560))
        window.setFrameAutosaveName("MarkdownSettings")
        super.init(window: window)
        // The title bar names the pane, as System Settings does.
        titleToken = model.$pane.sink { [weak window] pane in window?.title = pane.rawValue }
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusSearch()
        // The sidebar's list takes the keyboard when SwiftUI first lays the window out; the field is asked again after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let w = self.window, w.isVisible, (w.firstResponder as? NSTextView)?.isFieldEditor != true else { return }
            self.focusSearch()
        }
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

    /// Puts the caret in the search field (SwiftUI builds it a moment after the window shows, so this also tries again).
    func focusSearch(retries: Int = 10) {
        guard let window else { return }
        if let field = searchField { window.makeFirstResponder(field); return }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusSearch(retries: retries - 1) }
    }

    /// Edit > Find while this window is key: the search field, not the editor's find bar.
    @objc public override func performTextFinderAction(_ sender: Any?) { focusSearch() }
}
