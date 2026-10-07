import Foundation
import MarkdownCore

/// The library of notes behind the sidebar: the core's `Library` on a serial background queue,
/// kept in step with the roots' folders (a scan at start-up, then FSEvents), and queried for value
/// snapshots that are handed to the main thread. Nothing here touches AppKit, and nothing that
/// takes time (reading files, indexing, searching) runs on the main thread.
///
/// Every note a root holds is read through `DocumentFileAccess`. Open documents tell the library
/// their text as they are edited (`push`), so backlinks and tags follow typing without waiting
/// for a save.
public final class LibraryController {
    /// How long the file system gathers events before telling us (seconds).
    public static let eventLatency: TimeInterval = 0.5

    // MARK: main thread

    public private(set) var roots: [LibraryRootInfo] = []
    /// Counts the changes the library has announced.
    public private(set) var generation = 0
    /// The first scan of the current roots has not finished.
    public private(set) var isLoading = false

    private struct Observer {
        weak var owner: AnyObject?
        let handler: () -> Void
    }
    private var observers: [Observer] = []

    // MARK: queue

    private let queue = DispatchQueue(label: "markdown.library", qos: .userInitiated)
    private var library = Library()
    private var queueRoots: [LibraryRootInfo] = []
    private var entries: [String: [String: LibraryEntry]] = [:]
    private var stream: FileEventStream?
    private var queueGeneration = 0
    private var changedSinceAnnounced = false

    // MARK: bookkeeping shared with tests

    private let lock = NSLock()
    private var pending = 0
    private var announcePending = false

    public init() {}

    deinit { stream?.stop() }

    // MARK: observing

    /// `handler` runs on the main thread each time the library changed (a scan finished, a file
    /// changed, a note was pushed). Coalesced: several changes in a row make one call.
    public func observe(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    public func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
    }

    private func announce() {
        lock.lock()
        let already = announcePending
        announcePending = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [self] in
            lock.lock(); announcePending = false; lock.unlock()
            generation += 1
            let handlers = observers.filter { $0.owner != nil }.map(\.handler)
            for h in handlers { h() }
        }
    }

    // MARK: running work

    private func submit(_ work: @escaping () -> Void) {
        lock.lock(); pending += 1; lock.unlock()
        queue.async { [self] in
            work()
            lock.lock(); pending -= 1; lock.unlock()
        }
    }

    /// Hands a result to the main thread; the queue counts as busy until it has been delivered.
    private func deliver(_ block: @escaping () -> Void) {
        lock.lock(); pending += 1; lock.unlock()
        DispatchQueue.main.async { [self] in
            block()
            lock.lock(); pending -= 1; lock.unlock()
        }
    }

    /// True when every job sent to the queue has finished and its announcement has been made.
    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending == 0 && !announcePending
    }

    /// Spins the run loop until the queue is idle (tests, and the UI harness).
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if isIdle { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return isIdle
    }

    // MARK: roots

    /// Makes `new` the library's roots (in this order): folders no longer listed are forgotten, new
    /// ones are scanned and indexed, the file system is watched. Called again whenever the list
    /// changes.
    public func setRoots(_ new: [LibraryRootInfo]) {
        let canonical = new.map { LibraryRootInfo(id: $0.id, url: DocumentFileAccess.canonical($0.url)) }
        guard canonical != roots else { return }
        roots = canonical
        isLoading = true
        submit { [self] in
            reload(canonical)
            deliver { [self] in
                if canonical == roots { isLoading = false }
            }
            changedSinceAnnounced = false
            queueGeneration += 1
            announce()
        }
    }

    /// The note a file is, when it lies in one of the roots (symbolic links resolved).
    public func ref(for file: URL) -> NoteRef? {
        locate(file, in: roots).map { NoteRef(root: $0.root.id, path: $0.path) }
    }

    /// The file a note is.
    public func url(for note: NoteRef) -> URL? {
        roots.first { $0.id == note.root }.map { $0.url.appendingPathComponent(note.path) }
    }

    public func root(withID id: String) -> LibraryRootInfo? { roots.first { $0.id == id } }

    private func locate(_ file: URL, in roots: [LibraryRootInfo]) -> (root: LibraryRootInfo, path: String)? {
        let path = DocumentFileAccess.canonical(file).path
        for r in roots {
            let base = r.url.path.hasSuffix("/") ? r.url.path : r.url.path + "/"
            if path == r.url.path { return (r, "") }
            if path.hasPrefix(base) { return (r, String(path.dropFirst(base.count))) }
        }
        return nil
    }

    // MARK: loading (queue)

    private func reload(_ new: [LibraryRootInfo]) {
        stream?.stop()
        stream = nil
        let ids = Set(new.map(\.id))
        for old in queueRoots where !ids.contains(old.id) || new.first(where: { $0.id == old.id })?.url != old.url {
            _ = library.removeRoot(id: old.id)
            entries[old.id] = nil
        }
        var items: [NoteInput] = []
        for r in new where entries[r.id] == nil {
            library.addRoot(id: r.id, path: r.url.path)
            var table: [String: LibraryEntry] = [:]
            for e in LibraryScanner.scan(root: r.url) {
                table[e.path] = e
                if e.kind == .note, let item = noteInput(r, e) { items.append(item) }
            }
            entries[r.id] = table
        }
        queueRoots = new
        // All of them at once: the core parses on every core and resolves the link graph a single time.
        try? library.upsertAll(items: items)
        stream = FileEventStream(paths: new.map(\.url.path), latency: Self.eventLatency, queue: queue) { [weak self] events in
            self?.handle(events)
        }
    }

    private func noteInput(_ root: LibraryRootInfo, _ e: LibraryEntry) -> NoteInput? {
        guard let data = try? DocumentFileAccess.read(root.url.appendingPathComponent(e.path)), let text = NoteText.decode(data) else { return nil }
        return NoteInput(note: NoteRef(root: root.id, path: e.path), text: text, modified: Self.millis(e.modified))
    }

    private static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: following the file system (queue)

    private func handle(_ events: [FileEventStream.Event]) {
        var folders: [String] = []
        for e in events.sorted(by: { $0.path.count < $1.path.count }) {
            // Something already looked at everything below this folder in this batch.
            if folders.contains(where: { e.path == $0 || e.path.hasPrefix($0 + "/") }) { continue }
            if sync(path: e.path) { folders.append(e.path) }
        }
        finishChanges()
    }

    private func finishChanges() {
        guard changedSinceAnnounced else { return }
        changedSinceAnnounced = false
        queueGeneration += 1
        announce()
    }

    /// Brings the index in line with what `path` is now. True when the whole folder below it was
    /// looked at.
    @discardableResult
    private func sync(path: String) -> Bool {
        guard let (root, rel) = locate(URL(fileURLWithPath: path), in: queueRoots) else { return false }
        if rel.split(separator: "/").contains(where: { DocumentFileAccess.isSkipped(name: String($0)) }) { return false }
        let url = rel.isEmpty ? root.url : root.url.appendingPathComponent(rel)
        if rel.isEmpty { syncFolder(root, ""); return true }
        guard let fresh = LibraryScanner.entry(for: url, path: rel) else {
            removeSubtree(root, rel)
            return false
        }
        if fresh.kind == .folder {
            ensureFolders(root, above: rel)
            if entries[root.id]?[rel] != fresh { entries[root.id]?[rel] = fresh; changedSinceAnnounced = true }
            syncFolder(root, rel)
            return true
        }
        syncFile(root, fresh)
        return false
    }

    /// An entry whose folders the index has not seen yet (a file moved into a folder made a moment
    /// ago) must still be reachable from the root: its folders are entered too.
    private func ensureFolders(_ root: LibraryRootInfo, above path: String) {
        var folder = Workspace.parentPath(path)
        while !folder.isEmpty, entries[root.id]?[folder] == nil {
            if let e = LibraryScanner.entry(for: root.url.appendingPathComponent(folder), path: folder) {
                entries[root.id]?[folder] = e
                changedSinceAnnounced = true
            }
            folder = Workspace.parentPath(folder)
        }
    }

    private func syncFile(_ root: LibraryRootInfo, _ fresh: LibraryEntry) {
        let old = entries[root.id]?[fresh.path]
        ensureFolders(root, above: fresh.path)
        guard old != fresh else { return }
        entries[root.id]?[fresh.path] = fresh
        changedSinceAnnounced = true
        let ref = NoteRef(root: root.id, path: fresh.path)
        if fresh.kind == .note {
            if let item = noteInput(root, fresh) {
                try? library.upsert(note: item.note, text: item.text, modified: item.modified)
            } else {
                _ = library.remove(note: ref)
            }
        } else if old?.kind == .note {
            _ = library.remove(note: ref)
        }
    }

    private func syncFolder(_ root: LibraryRootInfo, _ folder: String) {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let fresh = Dictionary(LibraryScanner.scan(root: root.url, folder: folder).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for path in (entries[root.id] ?? [:]).keys where path.hasPrefix(prefix) && !path.isEmpty && fresh[path] == nil {
            removeSubtree(root, path)
        }
        for e in fresh.values.sorted(by: { $0.path < $1.path }) {
            if e.kind == .folder {
                if entries[root.id]?[e.path] != e { entries[root.id]?[e.path] = e; changedSinceAnnounced = true }
            } else {
                syncFile(root, e)
            }
        }
    }

    private func removeSubtree(_ root: LibraryRootInfo, _ rel: String) {
        guard let table = entries[root.id] else { return }
        for (path, e) in table where path == rel || path.hasPrefix(rel + "/") {
            if e.kind == .note { _ = library.remove(note: NoteRef(root: root.id, path: path)) }
            entries[root.id]?[path] = nil
            changedSinceAnnounced = true
        }
    }

    // MARK: what the app changed itself

    /// Looks at these places again at once (the app made or removed files there), instead of
    /// waiting for the file system's events.
    ///
    /// `force`: the note is read again even though its file looks unchanged (an open document had
    /// pushed text that was never saved).
    public func refresh(_ urls: [URL], force: Bool = false) {
        let paths = urls.map { DocumentFileAccess.canonical($0).path }
        submit { [self] in
            for p in paths {
                if force, let (root, rel) = locate(URL(fileURLWithPath: p), in: queueRoots) { entries[root.id]?[rel] = nil }
                sync(path: p)
            }
            finishChanges()
        }
    }

    /// A file or folder was moved from `old` to `new` (renamed, or dragged into another folder): the
    /// notes in it keep their place in the link graph, under their new paths.
    public func moved(from old: URL, to new: URL) {
        let oldPath = DocumentFileAccess.canonical(old).path, newPath = DocumentFileAccess.canonical(new).path
        submit { [self] in
            if let (oldRoot, oldRel) = locate(URL(fileURLWithPath: oldPath), in: queueRoots),
               let (newRoot, newRel) = locate(URL(fileURLWithPath: newPath), in: queueRoots), !oldRel.isEmpty, !newRel.isEmpty {
                for (path, e) in entries[oldRoot.id] ?? [:] where path == oldRel || path.hasPrefix(oldRel + "/") {
                    let moved = newRel + path.dropFirst(oldRel.count)
                    if e.kind == .note {
                        try? library.rename(old: NoteRef(root: oldRoot.id, path: path), new: NoteRef(root: newRoot.id, path: String(moved)))
                    }
                    entries[oldRoot.id]?[path] = nil
                }
                changedSinceAnnounced = true
            }
            sync(path: newPath)
            sync(path: oldPath)
            finishChanges()
        }
    }

    /// An open document's text, as it is now. Opened documents push on every edit (debounced by
    /// the caller); the index never waits for a save.
    ///
    /// Only for a note whose file the library has: a document whose file was deleted (or moved out of the
    /// roots) while it was open is not a note any more, and its text would stay in the index, with its links
    /// and tags, after the window closed. Saved again, it is found by the file system's events.
    public func push(_ note: NoteRef, text: String) {
        let now = Self.millis(Date())
        submit { [self] in
            guard queueRoots.contains(where: { $0.id == note.root }), entries[note.root]?[note.path]?.kind == .note else { return }
            try? library.upsert(note: note, text: text, modified: now)
            changedSinceAnnounced = true
            finishChanges()
        }
    }

    // MARK: queries

    /// What the sidebar shows for `query`, worked out on the queue.
    public func snapshot(for query: LibraryQuery, completion: @escaping (LibrarySnapshot) -> Void) {
        submit { [self] in
            var s = LibrarySnapshot()
            s.query = query
            s.generation = queueGeneration
            s.tags = library.tags()
            s.noteCount = Int(library.len())
            s.loading = false
            var only: Set<NoteRef>?
            if !query.tags.isEmpty {
                only = Set(library.notes(filter: LibraryFilter(tags: query.tags), sort: .nameAscending).map(\.note))
            }
            s.roots = LibraryTree.build(roots: queueRoots, entries: entries.mapValues { Array($0.values) }, sort: query.sort, only: only)
            if query.isSearching {
                let hits = library.search(query: query.search, limit: 60)
                s.hits = only.map { set in hits.filter { set.contains($0.note) } } ?? hits
            }
            deliver { [self] in
                s.loading = isLoading
                completion(s)
            }
        }
    }

    public func backlinks(of note: NoteRef, completion: @escaping ([NoteBacklink]) -> Void) {
        submit { [self] in
            let r = library.backlinks(note: note)
            deliver { completion(r) }
        }
    }

    /// The notes that name `note` without linking it.
    public func mentions(of note: NoteRef, completion: @escaping ([NoteMention]) -> Void) {
        submit { [self] in
            let r = library.mentions(note: note)
            deliver { completion(r) }
        }
    }

    /// The edit that turns a mention into a wikilink; nil when the text it was found in has moved on.
    public func linkMentionEdit(_ mention: NoteMention, completion: @escaping (LibraryEdit?) -> Void) {
        submit { [self] in
            let r = library.linkMentionEdit(mention: mention)
            deliver { completion(r) }
        }
    }

    public func quickOpen(_ query: String, limit: Int = 12, completion: @escaping ([QuickOpenMatch]) -> Void) {
        submit { [self] in
            let r = library.quickOpen(query: query, limit: UInt32(limit))
            deliver { completion(r) }
        }
    }

    public func resolve(_ target: String, from note: NoteRef, completion: @escaping (NoteRef?) -> Void) {
        submit { [self] in
            let r = library.resolveWikilink(from: note, target: target)
            deliver { completion(r) }
        }
    }

    public func meta(of note: NoteRef, completion: @escaping (NoteMeta?) -> Void) {
        submit { [self] in
            let r = library.note(note: note)
            deliver { completion(r) }
        }
    }

    /// The edits that keep links pointing at `old` once it is moved to `new`; asked before the move.
    public func renameEdits(from old: NoteRef, to new: NoteRef, completion: @escaping ([LibraryEdit]) -> Void) {
        submit { [self] in
            let r = library.renameEdits(old: old, new: new)
            deliver { completion(r) }
        }
    }

    /// The front matter edits that make the notes naming template `old` name `new` (a template was renamed).
    public func templateEdits(from old: String, to new: String, completion: @escaping ([LibraryEdit]) -> Void) {
        submit { [self] in
            let r = library.templateEdits(old: old, new: new)
            deliver { completion(r) }
        }
    }

    /// Every note in a folder (or below it), for the links a folder's rename would change.
    public func notes(under folder: String, root: String, completion: @escaping ([NoteRef]) -> Void) {
        submit { [self] in
            let prefix = folder.isEmpty ? "" : folder + "/"
            let r = (entries[root] ?? [:]).values.filter { $0.kind == .note && $0.path.hasPrefix(prefix) }.map { NoteRef(root: root, path: $0.path) }
            deliver { completion(r.sorted { $0.path < $1.path }) }
        }
    }

    /// The notes the library knows, for tests.
    public func count(completion: @escaping (Int) -> Void) {
        submit { [self] in
            let n = Int(library.len())
            deliver { completion(n) }
        }
    }
}
