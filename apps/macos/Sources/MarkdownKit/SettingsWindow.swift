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

/// The sidebar's search field: AppKit's, so Escape clears it and the harness finds an `NSSearchField`. After Escape
/// the list takes the keyboard, so the arrows move the pane next.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// Escape (the field editor's cancel) clears the field and hands the keyboard to the list beside it, so the
        /// arrows move the pane next.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if !control.stringValue.isEmpty {
                control.stringValue = ""
                parent.text = ""
            }
            if let window = control.window, let list = SettingsWindowController.firstTable(in: window.contentView) {
                window.makeFirstResponder(list)
            }
            return true
        }
    }
}

/// The sidebar: the search field under the window's controls, then the panes. Hosted in the split view controller's
/// sidebar item, which runs it the window's full height under the title bar with the sidebar's material.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // System Settings' measures: the field and the rows' highlight 15 points from the edge, rows 32 points tall,
        // the name 6 points from its tile.
        VStack(spacing: 0) {
            SearchField(text: $model.query)
                .padding(.horizontal, 15)
                .padding(.top, 52)
                .padding(.bottom, 10)
            List(model.panes, selection: Binding(get: { Optional(model.pane) }, set: { if let p = $0 { model.pane = p } })) { pane in
                Label { Text(pane.rawValue).padding(.leading, -2) } icon: { PaneTile(pane: pane) }
                    .frame(height: 24)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5)
        }
    }
}

/// The two columns: the sidebar (217 points, as System Settings') with its material, a divider, the pane.
struct SettingsWindowView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 217)
                .background(SidebarMaterial())
            Divider()
            SettingsView(model: model)
        }
        .ignoresSafeArea()
        .frame(width: 720, height: 672)
    }
}

/// The sidebar's material, behind the list and under the title bar.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
        VStack(alignment: .leading, spacing: 0) {
            // The pane's name where System Settings puts it: level with the window's controls, over the form.
            Text(model.pane.rawValue)
                .font(.system(size: 15, weight: .bold))
                .padding(.leading, 20)
                .frame(height: 52)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// `frameName` is the name the window's frame is saved under in the standard defaults; nil (tests, a UI script) saves none.
    public init(settings: Settings, frameName: String? = nil) {
        model = SettingsModel(settings: settings)
        // Laid out as System Settings is, by hand: on this OS a split view's sidebar item (AppKit's or SwiftUI's) is
        // drawn as a glass panel floating inset from the window's edge, which Apple's own app opts out of; a flat
        // full-height sidebar needs the two columns side by side with the sidebar's material behind the first.
        let host = NSHostingController(rootView: SettingsWindowView(model: model))
        let window = NSWindow(contentViewController: host)
        // Not resizable: the content pane scrolls, so no pane needs a taller window. The pane names itself where
        // System Settings does; the window's title is still set, for the Window menu and the harness, but not drawn.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 672))
        super.init(window: window)
        // Through the controller, not the window: a window controller hands its window its own autosave name when it
        // takes the window, which emptied the one set on the window before, so no frame was ever saved.
        if let frameName { windowFrameAutosaveName = frameName }
        // The title bar names the pane, as System Settings does.
        titleToken = model.$pane.sink { [weak window] pane in window?.title = pane.rawValue }
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        // Centred only the first time: after that the frame is where the person left it.
        if window?.isVisible != true, !hasSavedFrame { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // The list has the keyboard as the window opens (the arrows move the pane), as System Settings opens.
        if let window, let list = Self.firstTable(in: window.contentView) { window.makeFirstResponder(list) }
    }

    private var hasSavedFrame: Bool {
        !windowFrameAutosaveName.isEmpty && UserDefaults.standard.string(forKey: "NSWindow Frame \(windowFrameAutosaveName)") != nil
    }

    static func firstTable(in view: NSView?) -> NSTableView? {
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
        guard let window else { return }
        if let field = searchField { window.makeFirstResponder(field); return }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusSearch(retries: retries - 1) }
    }

    /// Edit > Find while this window is key: the search field, not the editor's find bar.
    @objc public override func performTextFinderAction(_ sender: Any?) { focusSearch() }
}
