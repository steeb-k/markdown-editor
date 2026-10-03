import AppKit
import MarkdownCore

/// One row of the sidebar's outline. A class, because NSOutlineView keeps what is expanded by
/// the identity of its items: a rebuilt tree reuses the items it had (by id), so a reload does not
/// collapse anything.
final class SidebarItem: NSObject {
    enum Kind {
        case node(LibraryNode)
        case tagsHeader
        case tag(name: String, count: Int)
        case hit(SearchHit)
        /// A line of text where rows would be ("No results").
        case message(String)
    }

    let id: String
    var kind: Kind
    var children: [SidebarItem] = []

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    var node: LibraryNode? { if case .node(let n) = kind { return n } else { return nil } }

    var isExpandable: Bool {
        switch kind {
        case .node(let n): return n.isFolder && !children.isEmpty
        case .tagsHeader: return !children.isEmpty
        default: return false
        }
    }

    /// Whether the row can be selected (tags and the header act on a click instead).
    var isSelectable: Bool {
        switch kind {
        case .node, .hit: return true
        default: return false
        }
    }

    var title: String {
        switch kind {
        case .node(let n): return n.name
        case .tagsHeader: return "Tags"
        case .tag(let name, _): return "#" + name
        case .hit(let h): return h.title
        case .message(let m): return m
        }
    }

    /// The file a row stands for (notes, folders, files and search hits).
    func url(in workspace: Workspace) -> URL? {
        switch kind {
        case .node(let n): return n.url
        case .hit(let h): return workspace.library.url(for: h.note)
        default: return nil
        }
    }
}

enum SidebarModel {
    /// The rows for a snapshot: while a search is typed its hits, else the roots' trees and the tags.
    /// `reuse` maps ids to the items of the previous tree.
    static func items(for snapshot: LibrarySnapshot, reuse: [String: SidebarItem] = [:]) -> [SidebarItem] {
        func item(_ id: String, _ kind: Kind) -> SidebarItem {
            if let old = reuse[id] { old.kind = kind; old.children = []; return old }
            return SidebarItem(id: id, kind: kind)
        }
        typealias Kind = SidebarItem.Kind
        if snapshot.query.isSearching {
            if snapshot.hits.isEmpty { return [item("message", .message(snapshot.loading ? "Searching\u{2026}" : "No results"))] }
            return snapshot.hits.map { item("hit:\($0.note.root):\($0.note.path)", .hit($0)) }
        }
        func build(_ n: LibraryNode) -> SidebarItem {
            let i = item(n.id, .node(n))
            i.children = n.children.map(build)
            return i
        }
        var out = snapshot.roots.map(build)
        if !snapshot.tags.isEmpty {
            let header = item("tags", .tagsHeader)
            header.children = snapshot.tags.map { item("tag:\($0.tag)", .tag(name: $0.tag, count: Int($0.count))) }
            out.append(header)
        }
        return out
    }

    /// Every item of a tree with its id, for reuse.
    static func index(_ items: [SidebarItem]) -> [String: SidebarItem] {
        var out: [String: SidebarItem] = [:]
        func walk(_ i: SidebarItem) {
            out[i.id] = i
            i.children.forEach(walk)
        }
        items.forEach(walk)
        return out
    }
}

extension LibrarySnapshot {
    /// What the sidebar would draw: the same tree, tags and hits (the generation and the loading flag
    /// are not drawn), so a snapshot that only differs in those need not reload the outline.
    func drawsSameAs(_ other: LibrarySnapshot) -> Bool {
        roots == other.roots && tags == other.tags && hits == other.hits && query == other.query && loading == other.loading
    }
}
