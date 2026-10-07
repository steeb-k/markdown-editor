import AppKit
import Combine
import SwiftUI
import MarkdownCore

/// A field of an element's style, by its key in `template.toml`. What the inspector shows for a kind, and what the harness
/// names in `{"templates": {"set": {...}}}`.
enum TemplateField: String, CaseIterable {
    case fontFamily = "font_family", fontSize = "font_size", weight, italic, color, background
    case spaceAbove = "space_above", spaceBelow = "space_below", lineHeight = "line_height", align, indent
    case letterSpacing = "letter_spacing", transform, decoration, border, radius, numbered, marker

    var title: String {
        switch self {
        case .fontFamily: return "Font"
        case .fontSize: return "Size"
        case .weight: return "Weight"
        case .italic: return "Italic"
        case .color: return "Colour"
        case .background: return "Background"
        case .spaceAbove: return "Space above"
        case .spaceBelow: return "Space below"
        case .lineHeight: return "Line height"
        case .align: return "Align"
        case .indent: return "Indent"
        case .letterSpacing: return "Letter spacing"
        case .transform: return "Transform"
        case .decoration: return "Decoration"
        case .border: return "Border"
        case .radius: return "Radius"
        case .numbered: return "Numbered"
        case .marker: return "Marker"
        }
    }

    /// Whether the field means anything for the kind: a field that does nothing is not offered (no border or radius for
    /// emphasis, no numbering for a paragraph).
    func applies(to kind: TemplateElementKind) -> Bool {
        let type: Set<TemplateField> = [.fontFamily, .fontSize, .weight, .italic, .color, .letterSpacing, .transform]
        let block: Set<TemplateField> = type.union([.background, .spaceAbove, .spaceBelow, .lineHeight, .align, .indent, .border, .radius])
        let set: Set<TemplateField>
        switch kind {
        case .body, .paragraph, .blockQuote, .footnotes: set = block.union([.decoration])
        case .h1, .h2, .h3: set = block.union([.decoration, .numbered])
        case .h4, .h5, .h6: set = block.union([.decoration])
        case .link: set = type.union([.decoration])
        case .emphasis, .strong: set = type.union([.decoration])
        case .inlineCode, .tag: set = type.union([.background, .decoration, .border, .radius])
        case .codeBlock: set = [.fontFamily, .fontSize, .weight, .italic, .color, .background, .spaceAbove, .spaceBelow, .lineHeight, .indent, .border, .radius]
        case .bulletList, .numberedList: set = [.fontFamily, .fontSize, .weight, .italic, .color, .spaceAbove, .spaceBelow, .lineHeight, .indent, .marker]
        case .taskItem: set = [.fontFamily, .fontSize, .weight, .italic, .color, .background, .spaceAbove, .spaceBelow, .lineHeight, .indent, .decoration]
        case .table: set = [.fontFamily, .fontSize, .color, .background, .spaceAbove, .spaceBelow, .lineHeight, .align, .border, .radius]
        case .tableHeader: set = [.fontFamily, .fontSize, .weight, .italic, .color, .background, .align, .letterSpacing, .transform, .border]
        case .rule: set = [.color, .spaceAbove, .spaceBelow, .border]
        case .image: set = [.spaceAbove, .spaceBelow, .align, .border, .radius]
        }
        return set.contains(self)
    }

    /// Copies this field from `source` to `target` (an unset field clears it).
    func copy(from source: TemplateElementStyle, to target: inout TemplateElementStyle) {
        switch self {
        case .fontFamily: target.fontFamily = source.fontFamily
        case .fontSize: target.fontSize = source.fontSize
        case .weight: target.weight = source.weight
        case .italic: target.italic = source.italic
        case .color: target.color = source.color
        case .background: target.background = source.background
        case .spaceAbove: target.spaceAbove = source.spaceAbove
        case .spaceBelow: target.spaceBelow = source.spaceBelow
        case .lineHeight: target.lineHeight = source.lineHeight
        case .align: target.align = source.align
        case .indent: target.indent = source.indent
        case .letterSpacing: target.letterSpacing = source.letterSpacing
        case .transform: target.transform = source.transform
        case .decoration: target.decoration = source.decoration
        case .border: target.border = source.border
        case .radius: target.radius = source.radius
        case .numbered: target.numbered = source.numbered
        case .marker: target.marker = source.marker
        }
    }
}

/// The page's fields, by their keys in the `[page]` table.
enum TemplatePageField: String, CaseIterable {
    case measureCh = "measure_ch", sidePadding = "side_padding", background, align

    func copy(from source: TemplatePage, to target: inout TemplatePage) {
        switch self {
        case .measureCh: target.measureCh = source.measureCh
        case .sidePadding: target.sidePadding = source.sidePadding
        case .background: target.background = source.background
        case .align: target.align = source.align
        }
    }
}

/// Which theme the sample page is drawn in: the app's own, or one of the two the Light/Dark switch chooses.
enum SampleAppearance: Equatable {
    case app, light, dark
}

/// The Templates window's model: the template selected in the list as it is being edited, the element the inspector
/// shows, and the stylesheet the sample page wears. Changes go three ways at once: to the stylesheet (at once), to the
/// package on disk (after a pause, like autosave), and to the window's undo manager (one step per field edit).
///
/// The list itself is the store's; this keeps the selection by the package's URL, so a rename or a change made in Finder
/// does not lose it. Main thread.
@MainActor
final class TemplateEditor: ObservableObject {
    /// "page", or the key of an element kind (`h1`, `code_block`).
    static let pageKey = "page"
    static let kinds: [TemplateElementInfo] = elementKinds()
    /// Seconds after a change before the package is written (a run of changes is one write).
    static let saveDelay: TimeInterval = 0.5
    /// Seconds within which changes to the same field are one undo step (typing a number, dragging a colour).
    static let coalesceWindow: TimeInterval = 1.0

    let store: TemplateStore
    let undoManager = UndoManager()

    @Published private(set) var templates: [InstalledTemplate] = []
    @Published private(set) var selectedID: URL?
    /// The selected template with the changes made so far (what the sample and the inspector show).
    @Published private(set) var working: InstalledTemplate?
    @Published var targetKey = "body"
    @Published private(set) var appearance: SampleAppearance = .app
    /// The sample page's stylesheet: the template's, in the sample's theme and the editor's type.
    @Published private(set) var css = ""
    /// Something went wrong that the window should say (a rename that could not be done, a package that would not save).
    @Published var problem: String?

    private var dirty = false
    private var saveTimer: Timer?
    private var lastEdit: (key: String, time: Date)?
    /// Store changes caused by the editor's own calls are looked at when the call is done, with the right selection.
    private var quiet = false
    private var observers: [NSObjectProtocol] = []
    /// Packages written by `flush`, for tests.
    private(set) var saves = 0

    init(store: TemplateStore = .shared) {
        self.store = store
        // One step per field edit (see `register`), however the run loop cuts its events.
        undoManager.groupsByEvent = false
        templates = store.templates
        selectedID = store.builtInDefault.id
        working = store.builtInDefault
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: TemplateStore.didChangeNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        })
        // The theme, the font and the line width are the sample's too.
        observers.append(center.addObserver(forName: Settings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.regenerate() }
        })
        regenerate()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: the list

    var builtIn: [InstalledTemplate] { templates.filter(\.isBuiltIn) }
    var yours: [InstalledTemplate] { templates.filter { !$0.isBuiltIn } }
    var isReadOnly: Bool { working?.isBuiltIn ?? true }
    /// Whether the inspector can change the selected template: not a built-in one, and not one whose `template.toml` could
    /// not be read (it is shown with its error, to be mended in the file or deleted).
    var isEditable: Bool { !isReadOnly && working?.isUsable == true }

    private func storeChanged() {
        guard !quiet else { return }
        refresh(keeping: selectedID)
    }

    /// Takes the store's list again and the selected template with it (unless it has changes not yet written: they win).
    private func refresh(keeping id: URL?) {
        templates = store.templates
        let found = templates.first { $0.id == id } ?? templates.first { $0.id == selectedID }
        guard let found else {
            // The selected template is gone (deleted in Finder): the Default.
            select(store.builtInDefault.id)
            return
        }
        if found.id != selectedID { selectedID = found.id }
        if dirty, found.id == working?.id { return }
        if working != found {
            working = found
            regenerate()
        }
    }

    func select(_ id: URL?) {
        guard let id, id != selectedID || working == nil, let t = store.templates.first(where: { $0.id == id }) else { return }
        flush()
        selectedID = id
        working = t
        // What was undone and redone belongs to the template that was open.
        undoManager.removeAllActions()
        lastEdit = nil
        regenerate()
    }

    func select(named name: String) -> Bool {
        guard let t = templates.first(where: { TemplateStore.key($0.name) == TemplateStore.key(name) }) else { return false }
        select(t.id)
        return true
    }

    // MARK: the element

    var targetKind: TemplateElementKind? { Self.kinds.first { $0.key == targetKey }?.kind }
    var isPage: Bool { targetKey == Self.pageKey }

    func selector(forKey key: String) -> String? {
        key == Self.pageKey ? "main.md" : Self.kinds.first { $0.key == key }?.selector
    }

    func selectTarget(_ key: String) {
        guard key == Self.pageKey || Self.kinds.contains(where: { $0.key == key }) else { return }
        targetKey = key
    }

    func style(for kind: TemplateElementKind) -> TemplateElementStyle {
        working?.spec.elements.first { $0.kind == kind }?.style ?? TemplateElementStyle()
    }

    var page: TemplatePage { working?.spec.page ?? TemplatePage() }

    // MARK: changing

    /// Binding for one field of the shown element; nil is "as the Default template".
    func binding<T>(_ kind: TemplateElementKind, _ field: TemplateField, _ path: WritableKeyPath<TemplateElementStyle, T?>) -> Binding<T?> {
        Binding(get: { self.style(for: kind)[keyPath: path] },
                set: { value in
                    self.change(key: "\(kind).\(field.rawValue)", actionName: "Change \(field.title)") { t in
                        Self.update(&t.spec, kind) { $0[keyPath: path] = value }
                    }
                })
    }

    func pageBinding<T>(_ field: TemplatePageField, _ title: String, _ path: WritableKeyPath<TemplatePage, T?>) -> Binding<T?> {
        Binding(get: { self.page[keyPath: path] },
                set: { value in
                    self.change(key: "page.\(field.rawValue)", actionName: "Change \(title)") { $0.spec.page[keyPath: path] = value }
                })
    }

    var descriptionBinding: Binding<String> {
        Binding(get: { self.working?.meta.description ?? "" },
                set: { value in self.change(key: "description", actionName: "Change Description") { $0.meta.description = value } })
    }

    /// Sets one element's style by a function; an element left with nothing set is dropped, so the file stays as small as
    /// what was said.
    static func update(_ spec: inout TemplateSpec, _ kind: TemplateElementKind, _ body: (inout TemplateElementStyle) -> Void) {
        var style = spec.elements.first { $0.kind == kind }?.style ?? TemplateElementStyle()
        body(&style)
        spec.elements.removeAll { $0.kind == kind }
        if style != TemplateElementStyle() { spec.elements.append(TemplateElement(kind: kind, style: style)) }
        // The core writes them in the order of the kinds, whatever order they were added in.
        let order = Self.kinds.map(\.kind)
        spec.elements.sort { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
    }

    /// Applies a change to the selected template (never a built-in one): the stylesheet, the write, the undo step.
    /// Changes with the same `key` close together are one step.
    ///
    /// A template whose `template.toml` could not be read is not changed: its styles here are empty, and the first save
    /// would have replaced the file (perhaps one typo away from right) with them. A change that would not read back is
    /// refused: the number fields take `nan`, `∞` and `1e400`, and a length written as `infem` makes the core refuse the
    /// whole file the next time it is read.
    func change(key: String, actionName: String, _ body: (inout Template) -> Void) {
        guard let current = working, !current.isBuiltIn, current.isUsable else { return }
        let before = current.template
        var after = before
        body(&after)
        guard after != before, Self.readsBack(after) else { return }
        register(undoTo: before, key: key, actionName: actionName, id: current.id)
        assign(after)
    }

    /// Whether `template` is written and read back as itself (so every number in it is finite: NaN is not even equal to
    /// itself).
    static func readsBack(_ template: Template) -> Bool {
        (try? parseTemplate(toml: templateToml(template: template))) == template
    }

    private func assign(_ template: Template) {
        guard var t = working else { return }
        t.meta = template.meta
        t.spec = template.spec
        working = t
        regenerate()
        scheduleSave()
    }

    private func register(undoTo before: Template, key: String, actionName: String, id: URL) {
        let replaying = undoManager.isUndoing || undoManager.isRedoing
        if replaying {
            // The inverse of what is being undone is the redo.
            undoManager.registerUndo(withTarget: self) { $0.replay(before, id: id, key: key, actionName: actionName) }
            return
        }
        let now = Date()
        if let last = lastEdit, last.key == key, now.timeIntervalSince(last.time) < Self.coalesceWindow, undoManager.canUndo {
            lastEdit = (key, now)
            return
        }
        lastEdit = (key, now)
        // A group of its own: one step per field edit, however the run loop happens to cut the events.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.replay(before, id: id, key: key, actionName: actionName) }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Undo or redo: puts `template` back, and registers what was there for the other direction.
    private func replay(_ template: Template, id: URL, key: String, actionName: String) {
        lastEdit = nil
        guard let current = working, current.id == id else { return }
        register(undoTo: current.template, key: key, actionName: actionName, id: id)
        assign(template)
    }

    // MARK: the stylesheet

    /// The editor's own look: its theme and type (what the document windows' preview wears).
    var appAppearance: EditorAppearance { EditorAppearance(settings: .shared, appearance: NSApp?.effectiveAppearance) }

    /// The theme the sample is drawn in.
    var sampleTheme: Theme {
        switch appearance {
        case .app: return appAppearance.theme
        case .light: return ThemeStore.shared.theme(id: "light")
        case .dark: return ThemeStore.shared.theme(id: "dark")
        }
    }

    var sampleIsDark: Bool { sampleTheme.isDark }

    func setSampleDark(_ dark: Bool) {
        appearance = dark ? .dark : .light
        regenerate()
    }

    private func regenerate() {
        guard let working else { return }
        let next = store.css(for: working, theme: sampleTheme, typography: PreviewTypography.make(from: appAppearance))
        if next != css { css = next }
    }

    // MARK: writing

    private func scheduleSave() {
        dirty = true
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    /// Writes the selected template now if it has changes not yet written (the window closes, the app quits, another
    /// template is chosen).
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard dirty, let t = working else { return }
        dirty = false
        guard !t.isBuiltIn else { return }
        quiet = true
        defer { quiet = false }
        do {
            try store.save(t)
            saves += 1
        } catch {
            problem = error.localizedDescription
        }
        templates = store.templates
        // `custom.css` and the modification time are the disk's.
        if let stored = templates.first(where: { $0.id == t.id }), stored.spec == t.spec, stored.meta == t.meta { working = stored }
    }

    // MARK: the list's own actions (the store, at once)

    /// Runs a store call that changes the list and then selects what it names.
    private func perform(_ body: () throws -> InstalledTemplate?) {
        flush()
        quiet = true
        defer { quiet = false }
        do {
            let made = try body()
            templates = store.templates
            if let made {
                selectedID = nil
                working = nil
                select(made.id)
            } else {
                refresh(keeping: selectedID)
            }
        } catch {
            problem = error.localizedDescription
            templates = store.templates
        }
    }

    func newTemplate() { perform { try store.create() } }

    func duplicateSelected() {
        guard let t = working else { return }
        perform { try store.duplicate(templates.first { $0.id == t.id } ?? t) }
    }

    func rename(to name: String) {
        guard let t = working, !t.isBuiltIn else { return }
        perform { try store.rename(templates.first { $0.id == t.id } ?? t, to: name) }
    }

    func deleteSelected() {
        guard let t = working, !t.isBuiltIn else { return }
        dirty = false
        saveTimer?.invalidate()
        perform {
            try store.delete(t)
            return store.builtInDefault
        }
    }

    func importTemplate(at url: URL) { perform { try store.importTemplate(at: url) } }

    func export(to url: URL, zipped: Bool) {
        guard let t = working else { return }
        flush()
        do { try store.export(templates.first { $0.id == t.id } ?? t, to: url, zipped: zipped) } catch { problem = error.localizedDescription }
    }

    // MARK: colours

    /// A theme colour as the sample's theme has it (a fixed colour that looks the same, for "Fixed" chosen over "Theme").
    func resolve(_ color: TemplateThemeColor) -> (UInt8, UInt8, UInt8) {
        let c = sampleTheme.colors
        let k: ThemeColor
        switch color {
        case .text: k = c.text
        case .heading: k = c.heading
        case .link: k = c.link
        case .quote: k = c.quote
        case .rule: k = c.rule
        case .border: k = c.tableBorder
        case .codeText: k = c.codeText
        case .codeBackground: k = c.codeBackground
        case .background: k = c.background
        case .markup: k = c.markup
        }
        return (k.r, k.g, k.b)
    }

    static let themeColors: [(TemplateThemeColor, String)] = [
        (.text, "Text"), (.heading, "Heading"), (.link, "Link"), (.quote, "Quote"), (.rule, "Rule"), (.border, "Border"),
        (.codeText, "Code text"), (.codeBackground, "Code background"), (.background, "Background"), (.markup, "Markup"),
    ]
}
