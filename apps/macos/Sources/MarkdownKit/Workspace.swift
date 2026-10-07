import AppKit
import MarkdownCore

/// What one window of notes has: the library (the app's, shared), the selection, the filters, the sort
/// and the folders opened in the sidebar. A window opened from another's sidebar starts with a copy
/// (`copy()`) and goes its own way; a note replacing a window's document hands the window's workspace on.
///
/// A workspace is plain state plus file operations. Windows and sheets belong to the window
/// controllers, which call into it and are told what changed.
public final class Workspace {
    public struct Change: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// A new snapshot of the library (tree, tags, hits).
        public static let snapshot = Change(rawValue: 1)
        public static let selection = Change(rawValue: 2)
        public static let filters = Change(rawValue: 4)
        public static let mode = Change(rawValue: 8)
        public static let layout = Change(rawValue: 16)
        public static let backlinks = Change(rawValue: 32)
        public static let expansion = Change(rawValue: 64)
        public static let scroll = Change(rawValue: 128)
        public static let all: Change = [.snapshot, .selection, .filters, .mode, .layout, .backlinks, .expansion, .scroll]
    }

    public let library: LibraryController
    public let settings: Settings

    /// Whether the window shows the sidebar.
    public private(set) var notesMode: Bool
    public private(set) var snapshot = LibrarySnapshot()
    /// What is selected in the sidebar's tree (node ids).
    public private(set) var selection: [String] = []
    /// The tags the list is filtered by: a note must have all of them.
    public private(set) var selectedTags: [String] = []
    public private(set) var searchText = ""
    public private(set) var sort: NoteSort
    /// Folders the user opened (node ids). Roots start opened.
    public private(set) var expanded: Set<String> = []
    public private(set) var collapsedTags = false
    public private(set) var backlinksShown = false
    public private(set) var sidebarWidth: CGFloat
    /// The sidebar's scroll position, kept so a document replacing the window's does not move the list.
    public private(set) var scrollOffset: CGFloat = 0
    /// A node that was just created: the sidebar starts renaming it when it appears.
    public var pendingRename: String?
    /// A note to open the folders above when the library's snapshot has it.
    var pendingReveal: String?
    /// The notes a Link of the Mentions section is being written into (see `linkMention`).
    var linkingMentions: Set<NoteRef> = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: (Change) -> Void
    }
    /// The window controllers using this workspace (two while a replacing window takes over from the one it closes).
    public let members = NSHashTable<AnyObject>.weakObjects()
    private var observers: [Observer] = []
    private var requestSeq = 0
    private var seenRoots: Set<String> = []

    /// An open document's edits waiting to reach the library (see `documentEdited`).
    struct PushState {
        var first: Date
        var item: DispatchWorkItem?
    }
    var pushes: [String: PushState] = [:]
    /// How long after the last edit of a burst the text is pushed, and the longest it waits.
    nonisolated(unsafe) public static var pushDelay: TimeInterval = 0.5
    nonisolated(unsafe) public static var pushLimit: TimeInterval = 1.0

    public init(library: LibraryController, settings: Settings, notesMode: Bool = false) {
        self.library = library
        self.settings = settings
        self.notesMode = notesMode
        sort = settings.noteSort
        sidebarWidth = CGFloat(settings.sidebarWidth)
        library.observe(self) { [weak self] in self?.libraryChanged() }
        if notesMode { requestSnapshot() }
    }

    deinit { library.stopObserving(self) }

    /// A workspace for another window that starts as this one is (its own selection and filters
    /// from here on): the window a Command-click opens.
    public func copy() -> Workspace {
        let w = Workspace(library: library, settings: settings, notesMode: notesMode)
        w.selection = selection
        w.selectedTags = selectedTags
        w.searchText = searchText
        w.expanded = expanded
        w.backlinksShown = backlinksShown
        w.collapsedTags = collapsedTags
        w.scrollOffset = scrollOffset
        w.snapshot = snapshot
        return w
    }

    /// The state a window was recorded in (see `SessionRecord`): the selection, the filters, the sort, the folders that were
    /// open, the width and the scroll position of the sidebar. A folder collapsed when the record was made stays collapsed
    /// (the roots that start opened are not opened again).
    public func restore(_ n: SessionRecord.Notes) {
        selection = n.selection ?? []
        selectedTags = n.tags ?? []
        searchText = n.search ?? ""
        if let s = n.sort.flatMap(NoteSort.init(rawValue:)) { sort = s }
        if let e = n.expanded {
            expanded = Set(e)
            seenRoots.formUnion(library.roots.map(\.id))
        }
        collapsedTags = n.tagsCollapsed ?? false
        backlinksShown = n.backlinks ?? false
        scrollOffset = CGFloat(n.scroll ?? 0)
        if let w = n.sidebarWidth { sidebarWidth = min(max(CGFloat(w), 160), 480) }
        if notesMode { requestSnapshot() }
    }

    // MARK: observing

    public func observe(_ owner: AnyObject, _ handler: @escaping (Change) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    public func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    private func notify(_ change: Change) {
        for o in observers where o.owner != nil { o.handler(change) }
    }

    // MARK: mode

    public func setNotesMode(_ on: Bool) {
        guard on != notesMode else { return }
        notesMode = on
        if on { requestSnapshot() }
        notify(.mode)
    }

    // MARK: the library's snapshot

    public var query: LibraryQuery { LibraryQuery(tags: selectedTags, search: searchText, sort: sort) }

    private func libraryChanged() {
        if notesMode { requestSnapshot() }
        notify(.backlinks)
    }

    /// Asks the library for the snapshot of the current query; an answer made obsolete by a newer
    /// question is dropped.
    public func requestSnapshot() {
        requestSeq += 1
        let seq = requestSeq
        library.snapshot(for: query) { [weak self] s in
            guard let self, seq == requestSeq else { return }
            snapshot = s
            // Each root starts opened, once.
            for r in s.roots where !seenRoots.contains(r.id) {
                seenRoots.insert(r.id)
                expanded.insert(r.id)
            }
            // A note that was just made (a draft) is shown once the library has it.
            if let id = pendingReveal, s.node(withID: id) != nil {
                pendingReveal = nil
                reveal(id)
            }
            // A tag that no note has any more cannot filter.
            let known = Set(s.tags.map(\.tag))
            if !selectedTags.isEmpty, !s.loading, selectedTags.contains(where: { !known.contains($0) }) {
                selectedTags.removeAll { !known.contains($0) }
                requestSnapshot()
            }
            notify(.snapshot)
        }
    }

    // MARK: sidebar state

    public func setSelection(_ ids: [String]) {
        guard ids != selection else { return }
        selection = ids
        notify(.selection)
    }

    public func setSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        requestSnapshot()
        notify(.filters)
    }

    public func toggleTag(_ tag: String) {
        if let i = selectedTags.firstIndex(of: tag) { selectedTags.remove(at: i) } else { selectedTags.append(tag) }
        requestSnapshot()
        notify(.filters)
    }

    public func clearTags() {
        guard !selectedTags.isEmpty else { return }
        selectedTags = []
        requestSnapshot()
        notify(.filters)
    }

    public func setSort(_ s: NoteSort) {
        guard s != sort else { return }
        sort = s
        settings.noteSort = s
        requestSnapshot()
        notify(.filters)
    }

    public func setExpanded(_ id: String, _ on: Bool) {
        if on { expanded.insert(id) } else { expanded.remove(id) }
        notify(.expansion)
    }

    public func setTagsCollapsed(_ on: Bool) {
        collapsedTags = on
        notify(.expansion)
    }

    public func setBacklinksShown(_ on: Bool) {
        guard on != backlinksShown else { return }
        backlinksShown = on
        notify([.layout, .backlinks])
    }

    public func setScrollOffset(_ y: CGFloat) {
        guard abs(y - scrollOffset) > 0.5 else { return }
        scrollOffset = y
        notify(.scroll)
    }

    public func setSidebarWidth(_ w: CGFloat) {
        let clamped = min(max(w, 160), 480)
        guard clamped != sidebarWidth else { return }
        sidebarWidth = clamped
        settings.sidebarWidth = Double(clamped)
        notify(.layout)
    }

    /// Opens every folder that leads to `id` (a note a link opened, so it can be seen in the tree).
    public func reveal(_ id: String) {
        guard let node = snapshot.node(withID: id) else {
            // Not in the tree yet (the note was made a moment ago): shown when it arrives.
            pendingReveal = id
            return
        }
        var path = node.path
        var changed = false
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            changed = expanded.insert(LibraryNode.id(root: node.root, path: path)).inserted || changed
        }
        if expanded.insert(node.root).inserted { changed = true }
        if changed { notify(.expansion) }
    }

    // MARK: finding things

    /// The folder New Note and New Folder go into: the selected folder, or the folder of the
    /// selected note, or else the library itself.
    public func destinationFolder() -> LibraryNode? {
        for id in selection {
            guard let node = snapshot.node(withID: id) else { continue }
            if node.isFolder { return node }
            if let parent = snapshot.node(withID: LibraryNode.id(root: node.root, path: Self.parentPath(node.path))) { return parent }
        }
        return snapshot.roots.first { !LibraryRootInfo.isAddedFolder(id: $0.root) } ?? snapshot.roots.first
    }

    public static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public func node(for url: URL) -> LibraryNode? {
        guard let ref = library.ref(for: url) else { return nil }
        return snapshot.node(withID: LibraryNode.id(root: ref.root, path: ref.path))
    }

    /// The library itself: the root that is not a folder the user added. Not merely the first: when the library's folder
    /// cannot be found (on a drive that is not connected), an added folder is first and must not be given the
    /// daily notes and the templates.
    public var primaryRoot: LibraryRootInfo? { library.roots.first { !$0.isAddedFolder } }

    // MARK: roots

    /// Makes `folder` a root of the library: the library itself when there is none yet, otherwise
    /// one the user added. Remembered as a bookmark.
    @discardableResult
    public func addRoot(_ folder: URL, asLibrary: Bool = false) -> LibraryRootInfo? {
        var grants = settings.libraryGrants
        let canonical = DocumentFileAccess.canonical(folder)
        if let existing = grants.first(where: { DocumentFileAccess.canonical(URL(fileURLWithPath: $0.path)) == canonical }) {
            return library.root(withID: existing.id)
        }
        let id: String
        if grants.isEmpty || (asLibrary && !grants.contains(where: { $0.id == LibraryRootInfo.libraryID })) {
            id = LibraryRootInfo.libraryID
        } else {
            var n = 2
            while grants.contains(where: { $0.id == LibraryRootInfo.addedFolderID(n) }) { n += 1 }
            id = LibraryRootInfo.addedFolderID(n)
        }
        let grant = DocumentFileAccess.makeGrant(id: id, folder: folder)
        if id == LibraryRootInfo.libraryID { grants.insert(grant, at: 0) } else { grants.append(grant) }
        settings.libraryGrants = grants
        applyGrants()
        return library.root(withID: id)
    }

    /// Makes `folder` the library itself: the root the library's id belongs to (the one that was is
    /// forgotten, its files stay where they are).
    public func setLibraryFolder(_ folder: URL) {
        var grants = settings.libraryGrants.filter { $0.id != LibraryRootInfo.libraryID }
        let canonical = DocumentFileAccess.canonical(folder)
        grants.removeAll { DocumentFileAccess.canonical(URL(fileURLWithPath: $0.path)) == canonical }
        grants.insert(DocumentFileAccess.makeGrant(id: LibraryRootInfo.libraryID, folder: folder), at: 0)
        settings.libraryGrants = grants
        applyGrants()
    }

    /// Takes a folder out of the library (the files stay where they are).
    public func removeRoot(id: String) {
        settings.libraryGrants = settings.libraryGrants.filter { $0.id != id }
        applyGrants()
    }

    /// Hands the remembered folders to the library controller (resolving their bookmarks).
    public func applyGrants() {
        let infos = settings.libraryGrants.compactMap { g in DocumentFileAccess.open(g).map { LibraryRootInfo(id: g.id, url: $0) } }
        library.setRoots(infos)
    }

    // MARK: registry of controllers

    private static var shared: [ObjectIdentifier: LibraryController] = [:]

    /// The one library controller for these settings: the roots are the app's, not a window's, so
    /// every workspace reads the same index.
    public static func libraryController(for settings: Settings) -> LibraryController {
        let key = ObjectIdentifier(settings)
        if let c = shared[key] { return c }
        let c = LibraryController()
        shared[key] = c
        let infos = settings.libraryGrants.compactMap { g in DocumentFileAccess.open(g).map { LibraryRootInfo(id: g.id, url: $0) } }
        c.setRoots(infos)
        return c
    }

    public static func make(settings: Settings, notesMode: Bool) -> Workspace {
        Workspace(library: libraryController(for: settings), settings: settings, notesMode: notesMode)
    }
}
