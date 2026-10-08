import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import MarkdownCore

/// One row of the sidebar: the template's name (a lock for the built-in ones), renamed in place on a double-click.
private struct TemplateRow: View {
    let template: InstalledTemplate
    @ObservedObject var editor: TemplateEditor
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if template.isBuiltIn {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Built in: duplicate it to edit")
                if editor.store.isHidden(template) {
                    Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary).help("Hidden by your template of the same name")
                }
            } else if !template.isUsable {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).help(template.error ?? "")
            }
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(template.name).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !template.isBuiltIn else { return }
            editor.select(template.id)
            draft = template.name
            editing = true
            focused = true
        }
        .tag(template.id)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != template.name { editor.rename(to: name) }
    }
}

private struct TemplatesSidebar: View {
    @ObservedObject var editor: TemplateEditor
    let actions: TemplatesWindowController

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { editor.selectedID }, set: { editor.select($0) })) {
                Section("Built in") {
                    ForEach(editor.builtIn) { TemplateRow(template: $0, editor: editor) }
                }
                Section("Yours") {
                    ForEach(editor.yours) { TemplateRow(template: $0, editor: editor) }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                button("New", "plus", "New template") { editor.newTemplate() }
                button("Duplicate", "plus.square.on.square", "Duplicate the selected template") { editor.duplicateSelected() }
                button("Import", "square.and.arrow.down", "Import a template\u{2026}") { actions.importTemplate() }
                button("Export", "square.and.arrow.up", "Export the selected template\u{2026}") { actions.exportTemplate() }
                Spacer()
                button("Delete", "trash", editor.isReadOnly ? "A built-in template cannot be deleted" : "Delete the selected template") { actions.confirmDelete() }
                    .disabled(editor.isReadOnly)
            }
            .padding(6)
        }
    }

    private func button(_ title: String, _ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.iconOnly) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(title)
    }
}

/// The sample page with the Light/Dark switch over it.
private struct TemplatesSample: View {
    @ObservedObject var editor: TemplateEditor
    let sample: TemplateSampleController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.working?.name ?? "").font(.headline).lineLimit(1)
                Spacer()
                Picker("Appearance", selection: Binding(get: { editor.sampleIsDark }, set: { editor.setSampleDark($0) })) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .help("The sample only: a document keeps the editor's own theme")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            TemplateSampleView(controller: sample)
        }
    }
}

private struct TemplatesRoot: View {
    @ObservedObject var editor: TemplateEditor
    let sample: TemplateSampleController
    let actions: TemplatesWindowController

    var body: some View {
        HSplitView {
            TemplatesSidebar(editor: editor, actions: actions)
                .frame(minWidth: 170, idealWidth: 200, maxWidth: 280)
            TemplatesSample(editor: editor, sample: sample)
                .frame(minWidth: 340, idealWidth: 520)
            TemplatesInspector(editor: editor)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
        }
        .frame(minWidth: 940, minHeight: 520)
    }
}

/// The Templates window (Window > Templates…, and Settings' "Manage Templates…"): a sidebar of the installed templates, the
/// sample page in the selected one, and an inspector for one element at a time. See PLAN 3.21.
public final class TemplatesWindowController: NSWindowController, NSWindowDelegate {
    /// No saved frame under a UI script, which runs under the app's own bundle identifier and so the person's defaults.
    public static let shared = TemplatesWindowController(store: .shared, frameName: sharedFrameName)

    private static var sharedFrameName: String? {
        #if DEBUG || UI_SCRIPT
        if UIScriptRunner.isRequested { return nil }
        #endif
        return "MarkdownTemplates"
    }

    let editor: TemplateEditor
    let sample = TemplateSampleController()
    private var cancellables: [AnyCancellable] = []
    private var terminating: NSObjectProtocol?

    /// `frameName` is the name the window's frame is saved under in the standard defaults; nil (tests, a UI script) saves none.
    public init(store: TemplateStore, frameName: String? = nil) {
        let editor = TemplateEditor(store: store)
        self.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Templates"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        editor.hostWindow = window
        let host = NSHostingController(rootView: TemplatesRoot(editor: editor, sample: sample, actions: self))
        // The hosting controller sizes the window by its content's ideal size; the saved frame and the minimum are ours.
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1180, height: 740))
        // Through the controller, not the window: a window controller hands its window its own autosave name when it
        // takes the window, which emptied the one set on the window before, so no frame was ever saved. After the
        // default size, so a saved frame wins over it.
        if let frameName { windowFrameAutosaveName = frameName }
        sample.onClick = { [weak editor] key in editor?.selectTarget(key) }
        // The sample follows the editor: stylesheet (a field, a template, the theme) and outlined element.
        editor.$css.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSample() }.store(in: &cancellables)
        editor.$targetKey.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSample() }.store(in: &cancellables)
        // Whatever went wrong with a list action is said once, on the window.
        editor.$problem.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] _ in self?.reportProblem() }.store(in: &cancellables)
        updateSample()
        terminating = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak editor] _ in
            MainActor.assumeIsolated { editor?.flush() }
        }
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { if let terminating { NotificationCenter.default.removeObserver(terminating) } }

    private func updateSample() {
        let appearance = editor.appAppearance
        let theme = editor.sampleTheme
        sample.show(css: editor.css, fonts: PreviewTypography.fontFaceCSS(for: appearance), outline: editor.selector(forKey: editor.targetKey),
                    background: ThemeStore.shared.palette(theme).background, theme: theme, typography: PreviewTypography.make(from: appearance))
    }

    public func show() {
        TemplateStore.openManager = { [weak self] in self?.show() }
        // A package may have changed in Finder since the window was last in front.
        editor.store.reloadIfChanged()
        // Centred only the first time: after that the frame is where the person left it.
        if window?.isVisible != true, !hasSavedFrame { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private var hasSavedFrame: Bool {
        !windowFrameAutosaveName.isEmpty && UserDefaults.standard.string(forKey: "NSWindow Frame \(windowFrameAutosaveName)") != nil
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        editor.flush()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        editor.store.reloadIfChanged()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editor.undoManager }

    // MARK: actions

    /// Asks before moving one of yours to the Trash (a sheet on the window).
    func confirmDelete() {
        guard let t = editor.working, !t.isBuiltIn, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(t.name)\u{201D}?"
        alert.informativeText = "The template is moved to the Trash. Documents that name it use the default template instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.editor.deleteSelected()
        }
    }

    func importTemplate() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a template (a .mdtemplate folder, a .iatemplate bundle, a .css file, or a zip archive of one)."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.editor.importTemplate(at: url)
        }
    }

    /// Export: a save panel whose file type is the choice between the package as a folder and as a zip.
    func exportTemplate() {
        guard let window, let t = editor.working else { return }
        let panel = NSSavePanel()
        panel.message = "Export \u{201C}\(t.name)\u{201D}"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        let kinds = ["Template folder (.mdtemplate)", "Zip archive (.mdtemplate.zip)"]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: kinds)
        let label = NSTextField(labelWithString: "File type:")
        let accessory = NSStackView(views: [label, popup])
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        let base = t.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base).\(TemplateStore.packageExtension)"
        let changer = ExportKindTarget(panel: panel, base: base)
        popup.target = changer
        popup.action = #selector(ExportKindTarget.changed(_:))
        panel.beginSheetModal(for: window) { [weak self] response in
            _ = changer
            guard response == .OK, let url = panel.url else { return }
            let zipped = popup.indexOfSelectedItem == 1
            self?.editor.export(to: url, zipped: zipped)
        }
    }

    /// Says what went wrong with the last list action, once.
    func reportProblem() {
        guard let message = editor.problem, let window else { return }
        editor.problem = nil
        let alert = NSAlert()
        alert.messageText = "The template could not be changed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}

/// Sets the save panel's file name to the type chosen in its popup (a folder `Name.mdtemplate`, or `Name.mdtemplate.zip`).
private final class ExportKindTarget: NSObject {
    let panel: NSSavePanel
    let base: String
    init(panel: NSSavePanel, base: String) { self.panel = panel; self.base = base }

    @objc func changed(_ sender: NSPopUpButton) {
        let ext = TemplateStore.packageExtension
        panel.nameFieldStringValue = sender.indexOfSelectedItem == 1 ? "\(base).\(ext).zip" : "\(base).\(ext)"
    }
}
