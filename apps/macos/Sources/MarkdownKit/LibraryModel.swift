import Foundation
import MarkdownCore

/// How the sidebar orders what is in a folder (folders first either way).
public enum NoteSort: String, CaseIterable, Sendable {
    case name, modified

    public var title: String { self == .name ? "Name" : "Date Modified" }
}

/// A folder the library scans. `id` is what `NoteRef.root` carries.
public struct LibraryRootInfo: Equatable, Hashable, Sendable {
    public var id: String
    public var url: URL
    public var name: String { url.lastPathComponent }

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }

    /// The id of the root the user's library lives in; further roots are numbered.
    public static let libraryID = "library"

    /// The id of the `n`th folder the user added (`folder-2`, ...).
    public static func addedFolderID(_ n: Int) -> String { "folder-\(n)" }
    public static func isAddedFolder(id: String) -> Bool { id.hasPrefix("folder-") }
    /// A folder added beside the library, not the library itself.
    public var isAddedFolder: Bool { Self.isAddedFolder(id: id) }
}

public enum LibraryEntryKind: Equatable, Sendable {
    case folder, note, other
}

/// One item of a root as the scan found it: a path relative to the root, `/` separated.
public struct LibraryEntry: Equatable, Sendable {
    public var path: String
    public var kind: LibraryEntryKind
    public var modified: Date
    public var size: Int

    public init(path: String, kind: LibraryEntryKind, modified: Date, size: Int) {
        self.path = path
        self.kind = kind
        self.modified = modified
        self.size = size
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var parent: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

/// One row of the sidebar's tree: a root, a folder, a note or a file that is not a note (shown
/// greyed). A value, built off the main thread and handed over whole.
public struct LibraryNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case root, folder, note, other }

    public var kind: Kind
    public var root: String
    /// Relative to the root; empty for the root itself.
    public var path: String
    /// What the row says: a note's file name without its extension, otherwise the whole name.
    public var name: String
    public var url: URL
    public var modified: Date
    public var children: [LibraryNode]

    /// Stable across snapshots: what selection and expansion are remembered by.
    public var id: String { LibraryNode.id(root: root, path: path) }
    public var note: NoteRef? { kind == .note ? NoteRef(root: root, path: path) : nil }
    public var isFolder: Bool { kind == .root || kind == .folder }

    public static func id(root: String, path: String) -> String { "\(root):\(path)" }

    /// Every note below (and including) this node.
    public var notes: [LibraryNode] {
        kind == .note ? [self] : children.flatMap(\.notes)
    }
}

/// What the sidebar asks the library for.
public struct LibraryQuery: Equatable, Sendable {
    public var tags: [String] = []
    public var search = ""
    public var sort: NoteSort = .name

    public init(tags: [String] = [], search: String = "", sort: NoteSort = .name) {
        self.tags = tags
        self.search = search
        self.sort = sort
    }

    public var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Everything the sidebar draws, as of one moment: the trees, the tags with their counts, and, while
/// a search is typed, its hits.
public struct LibrarySnapshot: Equatable, Sendable {
    public var generation = 0
    public var query = LibraryQuery()
    public var roots: [LibraryNode] = []
    public var tags: [TagCount] = []
    public var hits: [SearchHit] = []
    public var noteCount = 0
    /// The library's first scan has not finished.
    public var loading = false

    public init() {}

    public func node(withID id: String) -> LibraryNode? {
        func find(_ n: LibraryNode) -> LibraryNode? {
            if n.id == id { return n }
            for c in n.children { if let f = find(c) { return f } }
            return nil
        }
        for r in roots { if let f = find(r) { return f } }
        return nil
    }
}

/// The tree of a root, built from the flat list the scan makes.
public enum LibraryTree {
    /// `only`: show just these notes, with the folders that lead to them (a tag filter).
    public static func build(roots: [LibraryRootInfo], entries: [String: [LibraryEntry]], sort: NoteSort,
                             only: Set<NoteRef>? = nil) -> [LibraryNode] {
        roots.map { root in
            var node = LibraryNode(kind: .root, root: root.id, path: "", name: root.name, url: root.url,
                                   modified: .distantPast, children: [])
            let list = entries[root.id] ?? []
            var byParent: [String: [LibraryEntry]] = [:]
            for e in list { byParent[e.parent, default: []].append(e) }
            node.children = children(of: "", root: root, byParent: byParent, sort: sort, only: only)
            return node
        }
    }

    private static func children(of folder: String, root: LibraryRootInfo, byParent: [String: [LibraryEntry]],
                                 sort: NoteSort, only: Set<NoteRef>?) -> [LibraryNode] {
        var out: [LibraryNode] = []
        for e in byParent[folder] ?? [] {
            let url = root.url.appendingPathComponent(e.path, isDirectory: e.kind == .folder)
            switch e.kind {
            case .folder:
                let kids = children(of: e.path, root: root, byParent: byParent, sort: sort, only: only)
                if only != nil && kids.isEmpty { continue }
                out.append(LibraryNode(kind: .folder, root: root.id, path: e.path, name: e.name, url: url, modified: e.modified, children: kids))
            case .note:
                if let only, !only.contains(NoteRef(root: root.id, path: e.path)) { continue }
                out.append(LibraryNode(kind: .note, root: root.id, path: e.path, name: (e.name as NSString).deletingPathExtension,
                                       url: url, modified: e.modified, children: []))
            case .other:
                if only != nil { continue }
                out.append(LibraryNode(kind: .other, root: root.id, path: e.path, name: e.name, url: url, modified: e.modified, children: []))
            }
        }
        return ordered(out, by: sort)
    }

    /// Folders first, each group by name (as Finder compares: numbers by value, case ignored) or, for
    /// the files, the newest first.
    public static func ordered(_ nodes: [LibraryNode], by sort: NoteSort) -> [LibraryNode] {
        func byName(_ a: LibraryNode, _ b: LibraryNode) -> Bool {
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.path < b.path : c == .orderedAscending
        }
        let folders = nodes.filter(\.isFolder).sorted(by: byName)
        let files = nodes.filter { !$0.isFolder }
        switch sort {
        case .name: return folders + files.sorted(by: byName)
        case .modified:
            return folders + files.sorted { $0.modified == $1.modified ? byName($0, $1) : $0.modified > $1.modified }
        }
    }
}

/// A note's text as the editor shows it, from the bytes of its file.
public enum NoteText {
    /// The text the core is given: what `MarkdownDocument` would hold after reading these bytes (the
    /// BOM gone, line endings normalised to `\n`, the authorship block split off), so that every
    /// range the library reports is a range in the editor. Nil for a file that is not text.
    public static func decode(_ data: Data) -> String? {
        guard let decoded = try? TextCodec.decode(data) else { return nil }
        let split = splitAnnotations(fileText: decoded.raw)
        return split.annotations == nil ? decoded.text : TextCodec.normalize(split.body, decoded.lineEnding)
    }

    /// The bytes of a file whose text is replaced by `body`, in the same encoding, line endings and
    /// BOM, and with its authorship block (if it has one) kept as it was.
    public static func encode(_ body: String, replacing data: Data) -> Data? {
        guard let decoded = try? TextCodec.decode(data) else { return nil }
        let split = splitAnnotations(fileText: decoded.raw)
        var out = TextCodec.encode(body, hasBOM: decoded.hasBOM, lineEnding: decoded.lineEnding)
        if split.annotations != nil, let tail = split.rawTail { out.append(Data(tail.utf8)) }
        return out
    }

    /// The text with `edits` (ranges in UTF-16 units of that text) applied, last to first so that none
    /// moves another. Nil when an edit does not fit (the text is not the one the ranges were made for).
    public static func apply(_ edits: [LibraryEdit], to text: String) -> String? {
        let ns = NSMutableString(string: text)
        var last = Int.max
        for e in edits.sorted(by: { $0.range.start > $1.range.start }) {
            let r = NSRange(location: Int(e.range.start), length: Int(e.range.end - e.range.start))
            guard NSMaxRange(r) <= last, NSMaxRange(r) <= ns.length else { return nil }
            ns.replaceCharacters(in: r, with: e.replacement)
            last = r.location
        }
        return ns as String
    }
}
