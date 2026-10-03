#if DEBUG || UI_SCRIPT
import AppKit
import MarkdownCore

/// The harness's steps for notes mode: the library, the sidebar, the file operations, the palette.
/// Everything goes through the paths a person uses (the sidebar's click handler, the menus' actions,
/// the search field's delegate); what a step cannot do through the real dialogs it does through
/// the same calls the dialogs make.
extension UIScriptRunner {
    /// The window controller of the tab in front.
    var notesController: EditorWindowController? {
        (controller?.window?.tabGroup?.selectedWindow?.windowController as? EditorWindowController) ?? controller
    }

    var workspaceNow: Workspace? { notesController?.workspace }

    /// What a script's text means: `$TODAY` is today's note name, `$LIB` the library folder.
    func expandVars(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "$TODAY", with: DailyNote.name(for: Date(), format: Settings.shared.dailyFormat))
        out = out.replacingOccurrences(of: "$ISODATE", with: DailyNote.render(Date(), format: "YYYY-MM-DD"))
        if let root = workspaceNow?.primaryRoot { out = out.replacingOccurrences(of: "$LIB", with: root.url.path) }
        return out
    }

    /// Calls `then` once `condition` holds (true) or the time is up (false), checking every few milliseconds.
    func waitFor(_ timeout: TimeInterval, _ condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        func poll() {
            if condition() { then(true); return }
            if Date() >= deadline { then(false); return }
            later(0.03, poll)
        }
        poll()
    }

    /// The id of a node as a script writes it: a path in the library (`Projects/Alpha.md`, empty for the
    /// root), or `root:path`.
    func nodeID(_ s: String) -> String {
        s.contains(":") && !s.hasPrefix(":") && s.split(separator: ":", maxSplits: 1).first.map({ !$0.contains("/") && !$0.contains(" ") }) == true
            ? s : LibraryNode.id(root: LibraryRootInfo.libraryID, path: s)
    }

    /// The library settled: nothing queued, and the sidebar's snapshot is the library's latest.
    private func libraryQuiet(_ ws: Workspace) -> Bool {
        ws.library.isIdle && !ws.library.isLoading && ws.snapshot.generation >= ws.library.generation - 1
    }

    func notesStep(_ n: [String: Any], then done: @escaping () -> Void) {
        func str(_ k: String) -> String? { n[k] as? String }
        func num(_ k: String) -> Double? { (n[k] as? NSNumber)?.doubleValue }

        if let src = str("library") {
            // A copy of a folder of notes becomes the library (the script never touches the original).
            let from = resolve(src)
            let dst = outDir.appendingPathComponent("work", isDirectory: true).appendingPathComponent(from.lastPathComponent, isDirectory: true)
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            let ok = (try? FileManager.default.copyItem(at: from, to: dst)) != nil
            let ws = workspaceNow ?? Workspace.make(settings: Settings.shared, notesMode: false)
            ws.setLibraryFolder(dst)
            record(["notes library": dst.path], ok: ok)
            waitFor(20, { ws.library.isIdle && !ws.library.isLoading }) { _ in done() }
        } else if let src = str("addRoot") {
            let from = resolve(src)
            let dst = outDir.appendingPathComponent("work", isDirectory: true).appendingPathComponent(from.lastPathComponent, isDirectory: true)
            try? FileManager.default.removeItem(at: dst)
            let ok = (try? FileManager.default.copyItem(at: from, to: dst)) != nil
            workspaceNow?.addRoot(dst)
            record(["notes addRoot": dst.path], ok: ok && workspaceNow != nil)
            waitFor(20, { self.workspaceNow.map { $0.library.isIdle && !$0.library.isLoading } ?? true }) { _ in done() }
        } else if n["waitLoaded"] != nil {
            guard let ws = workspaceNow else { record(["notes waitLoaded": "no workspace"], ok: false); done(); return }
            ws.requestSnapshot()
            waitFor(num("waitLoaded") ?? 20, { self.libraryQuiet(ws) && ws.snapshot.noteCount > 0 }) { ok in
                self.record(["notes waitLoaded": ok, "notes": ws.snapshot.noteCount, "tags": ws.snapshot.tags.count], ok: ok)
                done()
            }
        } else if let id = str("click") {
            click(nodeID(id), option: n["option"] as? Bool ?? false, then: done)
        } else if let ids = n["select"] as? [String] {
            workspaceNow?.setSelection(ids.map(nodeID))
            record(["notes select": ids], ok: workspaceNow != nil)
            later(0.1, done)
        } else if let id = str("expand") {
            workspaceNow?.setExpanded(nodeID(id), n["on"] as? Bool ?? true)
            record(["notes expand": id], ok: workspaceNow != nil)
            later(0.1, done)
        } else if let text = str("search") {
            search(text, then: done)
        } else if n["escape"] != nil {
            guard let sb = notesController?.sidebar else { record(["notes escape": "no sidebar"], ok: false); done(); return }
            let editor = sb.view.searchField.currentEditor() as? NSTextView ?? NSTextView()
            let handled = sb.control(sb.view.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            record(["notes escape": handled, "search": workspaceNow?.searchText ?? ""], ok: handled)
            waitFor(3, { self.workspaceNow?.snapshot.query.search == self.workspaceNow?.searchText }) { _ in done() }
        } else if let tag = str("tag") {
            guard let sb = notesController?.sidebar, let item = sb.item(withID: "tag:\(tag)") else {
                record(["notes tag": tag, "error": "no such tag row"], ok: false)
                done()
                return
            }
            sb.activate(item)
            let ws = workspaceNow
            waitFor(5, { ws?.snapshot.query.tags == ws?.selectedTags }) { ok in
                self.record(["notes tag": tag, "selected": ws?.selectedTags ?? []], ok: ok)
                done()
            }
        } else if n["clearTags"] != nil {
            workspaceNow?.clearTags()
            let ws = workspaceNow
            waitFor(5, { ws?.snapshot.query.tags.isEmpty ?? true }) { _ in
                self.record(["notes clearTags": true], ok: ws != nil)
                done()
            }
        } else if let sort = str("sort") {
            menuAction(sort == "modified" ? #selector(EditorWindowController.sortNotesByModified(_:)) : #selector(EditorWindowController.sortNotesByName(_:)))
            let ws = workspaceNow
            waitFor(5, { ws?.snapshot.query.sort == ws?.sort }) { ok in
                self.record(["notes sort": sort], ok: ok)
                done()
            }
        } else if n["newNote"] != nil {
            newNote(then: done)
        } else if let text = str("commitRename") {
            guard let sb = notesController?.sidebar, sb.isRenaming else { record(["notes commitRename": text, "error": "nothing is being renamed"], ok: false); done(); return }
            let ws = workspaceNow
            sb.commitRename(text)
            waitFor(5, { !sb.isRenaming && (ws?.library.isIdle ?? true) }) { _ in
                later(0.4) {
                    self.followSelectedTab()
                    self.record(["notes commitRename": text, "document": self.document?.fileURL?.lastPathComponent ?? ""], ok: true)
                    done()
                }
            }
        } else if let r = n["rename"] as? [String: String], let path = r["path"], let to = r["to"] {
            // Rename in the sidebar, as Return and typing do; a question about links shows as a sheet.
            guard let sb = notesController?.sidebar else { record(["notes rename": path, "error": "no sidebar"], ok: false); done(); return }
            let id = nodeID(path)
            sb.beginRename(id: id, thenEditor: false)
            let started = sb.isRenaming
            sb.commitRename(to)
            later(0.8) {
                self.record(["notes rename": path, "to": to, "started": started, "sheet": self.window?.attachedSheet != nil], ok: started)
                done()
            }
        } else if let path = str("trash") {
            trash(path, then: done)
        } else if let name = str("newFromTemplate") {
            guard let c = notesController, let ws = c.workspace, let t = ws.templates().first(where: { $0.deletingPathExtension().lastPathComponent == name }) else {
                record(["notes newFromTemplate": name, "error": "no such template"], ok: false)
                done()
                return
            }
            let before = NSDocumentController.shared.documents.count
            c.newNote(fromTemplate: t)
            waitFor(5, { NSDocumentController.shared.documents.count > before }) { ok in
                later(0.3) {
                    self.followSelectedTab()
                    self.record(["notes newFromTemplate": name, "document": self.document?.fileURL?.lastPathComponent ?? ""], ok: ok)
                    done()
                }
            }
        } else if n["todaysNote"] != nil {
            let before = NSDocumentController.shared.documents.count
            let front = notesController?.markdownDocument
            menuAction(#selector(EditorWindowController.todaysNote(_:)))
            waitFor(5, { NSDocumentController.shared.documents.count > before || (self.notesController?.markdownDocument !== front) }) { _ in
                later(0.3) {
                    self.followSelectedTab()
                    self.record(["notes todaysNote": self.document?.fileURL?.lastPathComponent ?? "", "documents": NSDocumentController.shared.documents.count], ok: self.document != nil)
                    done()
                }
            }
        } else if let needle = str("cmdClickWikilink") {
            cmdClickWikilink(needle, expect: str("expect") ?? "open", then: done)
        } else if let b = n["backlinks"] as? [String: Any] {
            awaitBacklinks(b, then: done)
        } else if let title = str("clickBacklink") {
            // A click on a row of the backlinks panel: the note opens with the link selected.
            guard let c = notesController, let link = c.sidebar?.view.backlinks.links.first(where: { $0.fromTitle == title }),
                  let url = c.workspace?.library.url(for: link.from) else {
                record(["notes clickBacklink": title, "error": "no such row"], ok: false)
                done()
                return
            }
            c.sidebar?.view.backlinks.onOpen?(link)
            waitFor(5, { self.notesController?.markdownDocument?.fileURL.map { DocumentFileAccess.canonical($0) == DocumentFileAccess.canonical(url) } ?? false }) { ok in
                later(0.3) {
                    self.followSelectedTab()
                    self.record(["notes clickBacklink": title, "selection": self.textView.map { NSStringFromRange($0.selectedRange()) } ?? "",
                                 "selectedText": self.textView.map { ((self.session?.text ?? "") as NSString).substring(with: $0.selectedRange()) } ?? ""], ok: ok)
                    done()
                }
            }
        } else if n["newFolder"] != nil {
            let ws = workspaceNow
            let before = ws?.snapshot.noteCount
            menuAction(#selector(EditorWindowController.newFolder(_:)))
            let sb = notesController?.sidebar
            waitFor(5, { sb?.isRenaming == true }) { ok in
                self.record(["notes newFolder": ok, "notes before": before ?? -1], ok: ok)
                done()
            }
        } else if let d = n["duplicate"] as? String {
            guard let c = notesController, let sb = c.sidebar else { record(["notes duplicate": d, "error": "no sidebar"], ok: false); done(); return }
            workspaceNow?.setSelection([nodeID(d)])
            sb.view.layoutSubtreeIfNeeded()
            c.duplicateSelection(nil)
            waitFor(10, { self.workspaceNow?.library.isIdle ?? true }) { _ in
                later(0.3) { self.record(["notes duplicate": d, "selected": self.workspaceNow?.selection ?? []], ok: true); done() }
            }
        } else if let d = n["reveal"] as? String {
            var revealed: [URL] = []
            FileRevealer.revealed = { revealed = $0; return true }
            workspaceNow?.setSelection([nodeID(d)])
            notesController?.sidebar?.view.layoutSubtreeIfNeeded()
            notesController?.revealSelection(nil)
            FileRevealer.revealed = nil
            record(["notes reveal": d, "urls": revealed.map(\.path)], ok: revealed.count == 1)
            done()
        } else if let m = n["move"] as? [String: String], let path = m["path"], let into = m["into"] {
            moveItem(path, into: into, then: done)
        } else if let m = n["dropFromFinder"] as? [String: String], let from = m["from"], let into = m["into"] {
            guard let c = notesController, let ws = c.workspace, let folder = ws.snapshot.node(withID: nodeID(into)) else {
                record(["notes dropFromFinder": from, "error": "no such folder"], ok: false)
                done()
                return
            }
            let src = outDir.appendingPathComponent("outside", isDirectory: true)
            try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let file = src.appendingPathComponent(resolve(from).lastPathComponent)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.copyItem(at: resolve(from), to: file)
            c.copyItems([file], into: folder.url)
            waitFor(10, { ws.library.isIdle }) { _ in
                later(0.5) { self.record(["notes dropFromFinder": from, "into": into], ok: true); done() }
            }
        } else if n["showBacklinks"] != nil {
            let on = n["showBacklinks"] as? Bool ?? true
            if workspaceNow?.backlinksShown != on { menuAction(#selector(EditorWindowController.toggleBacklinks(_:))) }
            record(["notes showBacklinks": on], ok: workspaceNow?.backlinksShown == on)
            later(0.4, done)
        } else if n["focusSearch"] != nil {
            menuAction(#selector(EditorWindowController.searchLibrary(_:)))
            let sb = notesController?.sidebar
            record(["notes focusSearch": sb?.view.searchField.currentEditor() != nil], ok: sb?.view.searchField.currentEditor() != nil)
            done()
        } else if let w = num("sidebarWidth") {
            workspaceNow?.setSidebarWidth(CGFloat(w))
            record(["notes sidebarWidth": w], ok: workspaceNow != nil)
            later(0.3, done)
        } else if let p = n["probeTabSwitch"] as? [String: Any], let to = p["to"] as? Int {
            probeTabSwitch(to: to, then: done)
        } else if n["settle"] != nil {
            guard let ws = workspaceNow else { done(); return }
            ws.requestSnapshot()
            waitFor(num("settle") ?? 10, { self.libraryQuiet(ws) }) { _ in later(0.4, done) }
        } else if n["dumpRows"] != nil {
            let sb = notesController?.sidebar
            record(["notes rows": sb?.visibleRowTitles ?? [], "selected": sb?.selectedRowIDs ?? [], "reloads": sb?.reloads ?? 0,
                    "skippedReloads": sb?.skippedReloads ?? 0, "scroll": workspaceNow?.scrollOffset ?? 0], ok: true)
            done()
        } else if let on = n["mode"] as? Bool {
            if workspaceNow?.notesMode != on || (workspaceNow == nil && on) { menuAction(#selector(EditorWindowController.toggleNotesMode(_:))) }
            later(0.3) {
                self.record(["notes mode": on, "sidebar": self.notesController?.sidebar != nil], ok: (self.workspaceNow?.notesMode ?? false) == on)
                done()
            }
        } else if let k = n["setting"] as? [String: Any] {
            let st = Settings.shared
            if let v = k["dailyFolder"] as? String { st.dailyFolder = v }
            if let v = k["dailyFormat"] as? String { st.dailyFormat = v }
            if let v = k["templatesFolder"] as? String { st.templatesFolder = v }
            if let v = k["notesModeByDefault"] as? Bool { st.notesModeByDefault = v }
            record(["notes setting": k], ok: true)
            done()
        } else {
            record(["unknown notes step": "\(n)"], ok: false)
            done()
        }
    }

    // MARK: clicking, searching, creating

    private func click(_ id: String, option: Bool, then done: @escaping () -> Void) {
        guard let c = notesController, let sb = c.sidebar, let item = sb.item(withID: id) else {
            record(["notes click": id, "error": "no such row"], ok: false)
            done()
            return
        }
        let target = item.node?.url
        let docsBefore = NSDocumentController.shared.documents.count
        sb.activate(item, replacing: option)
        func arrived() -> Bool {
            if self.window?.attachedSheet != nil { return true }
            guard let target else { return true }
            let front = self.notesController?.markdownDocument?.fileURL
            return front.map { DocumentFileAccess.canonical($0) == DocumentFileAccess.canonical(target) } ?? false
        }
        waitFor(5, arrived) { ok in
            later(0.25) {
                self.followSelectedTab()
                let tabs = self.window.map { TabStripModel.entries(of: $0).map(\.title) } ?? []
                self.record(["notes click": id, "option": option, "documents": NSDocumentController.shared.documents.count, "documents_before": docsBefore,
                             "tabs": tabs, "sheet": self.window?.attachedSheet != nil], ok: ok || option)
                done()
            }
        }
    }

    private func search(_ text: String, then done: @escaping () -> Void) {
        guard let sb = notesController?.sidebar, let ws = workspaceNow else { record(["notes search": text, "error": "no sidebar"], ok: false); done(); return }
        sb.view.searchField.stringValue = text
        sb.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sb.view.searchField))
        waitFor(5, { ws.snapshot.query.search == text && (text.isEmpty || !ws.snapshot.loading) }) { ok in
            later(0.2) {
                self.record(["notes search": text, "rows": sb.visibleRowTitles, "hits": ws.snapshot.hits.count], ok: ok)
                done()
            }
        }
    }

    private func newNote(then done: @escaping () -> Void) {
        let before = NSDocumentController.shared.documents.count
        // File > New. (Sent to the window's controller itself: with the app not active the menu's action would
        // reach the document controller, whose New makes an untitled document.)
        notesController?.newDocument(nil)
        waitFor(6, { NSDocumentController.shared.documents.count > before && self.notesController?.sidebar?.isRenaming == true }) { ok in
            self.followSelectedTab()
            self.record(["notes newNote": self.document?.fileURL?.lastPathComponent ?? "", "renaming": self.notesController?.sidebar?.isRenaming ?? false], ok: ok)
            done()
        }
    }

    private func trash(_ path: String, then done: @escaping () -> Void) {
        guard let c = notesController, let ws = c.workspace, let sb = c.sidebar else { record(["notes trash": path, "error": "no sidebar"], ok: false); done(); return }
        var trashed: [(URL, URL?)] = []
        DocumentFileAccess.trashObserver = { trashed.append(($0, $1)) }
        ws.setSelection([nodeID(path)])
        sb.view.layoutSubtreeIfNeeded()
        c.trashSelection(nil)
        waitFor(6, { !trashed.isEmpty || self.window?.attachedSheet != nil }) { ok in
            DocumentFileAccess.trashObserver = nil
            let landed = trashed.first?.1.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let original = trashed.first.map { FileManager.default.fileExists(atPath: $0.0.path) } ?? true
            self.lastTrashed = (landed, original, trashed.first?.1?.path ?? "")
            // The harness's own copy is cleaned out of the Trash again; nothing of the user's is touched.
            if let t = trashed.first?.1, t.path.contains("/.Trash/") { try? FileManager.default.removeItem(at: t) }
            later(0.5) {
                self.followSelectedTab()
                self.record(["notes trash": path, "trashed": trashed.map { $0.1?.path ?? "" }, "inTrash": landed, "originalGone": !original], ok: ok)
                done()
            }
        }
    }

    private func moveItem(_ path: String, into folder: String, then done: @escaping () -> Void) {
        guard let c = notesController, let ws = c.workspace, let node = ws.snapshot.node(withID: nodeID(path)),
              let dest = ws.snapshot.node(withID: nodeID(folder)) else {
            record(["notes move": path, "error": "no such row"], ok: false)
            done()
            return
        }
        c.moveItems([node.url], into: dest.url)
        later(0.8) {
            self.record(["notes move": path, "into": folder, "sheet": self.window?.attachedSheet != nil], ok: true)
            done()
        }
    }

    // MARK: wikilinks and backlinks

    private func cmdClickWikilink(_ needle: String, expect: String, then done: @escaping () -> Void) {
        guard let tv = notesController?.textView ?? textView, let lm = tv.layoutManager, let tc = tv.textContainer else {
            record(["notes cmdClickWikilink": needle, "error": "no editor"], ok: false)
            done()
            return
        }
        let text = (notesController?.session ?? session)?.text ?? ""
        let r = (text as NSString).range(of: needle)
        guard r.location != NSNotFound else { record(["notes cmdClickWikilink": needle, "error": "not in the text"], ok: false); done(); return }
        let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: 1), actualCharacterRange: nil)
        let b = lm.boundingRect(forGlyphRange: g, in: tc)
        let o = tv.textContainerOrigin
        let beforeDoc = notesController?.markdownDocument
        let beforeDocs = NSDocumentController.shared.documents.count
        Self.opened = nil
        let hit = tv.openLink(at: NSPoint(x: b.midX + o.x, y: b.midY + o.y))
        waitFor(3, {
            self.window?.attachedSheet != nil || NSDocumentController.shared.documents.count > beforeDocs
                || self.notesController?.markdownDocument !== beforeDoc || Self.opened != nil
        }) { arrived in
            later(0.3) {
                let sheet = self.window?.attachedSheet != nil
                let opened = self.notesController?.markdownDocument !== beforeDoc
                self.followSelectedTab()
                let ok: Bool
                switch expect {
                case "offer": ok = hit && sheet
                case "none": ok = hit && !arrived
                case "external": ok = hit && Self.opened != nil
                default: ok = hit && opened
                }
                self.record(["notes cmdClickWikilink": needle, "hit": hit, "opened": opened, "sheet": sheet, "external": Self.opened?.lastPathComponent ?? "",
                             "document": self.document?.fileURL?.lastPathComponent ?? ""], ok: ok)
                done()
            }
        }
    }

    /// The backlinks panel of the window holding a note shows these linking notes within a time (measured from
    /// the start of the step, which follows the typing that made them).
    private func awaitBacklinks(_ b: [String: Any], then done: @escaping () -> Void) {
        guard let path = b["of"] as? String, let ws = workspaceNow, let ref = Optional(NoteRef(root: LibraryRootInfo.libraryID, path: path)),
              let url = ws.library.url(for: ref), let doc = NSDocumentController.shared.document(for: url) as? MarkdownDocument,
              let c = doc.windowControllers.first as? EditorWindowController else {
            record(["notes backlinks": b["of"] ?? "", "error": "that note is not open"], ok: false)
            done()
            return
        }
        let want = b["contains"] as? [String] ?? []
        let lack = b["lacks"] as? [String] ?? []
        let within = (b["within"] as? NSNumber)?.doubleValue ?? 1.0
        let started = Date()
        func titles() -> [String] { c.sidebar?.view.backlinks.links.map(\.fromTitle) ?? [] }
        func good() -> Bool { want.allSatisfy { titles().contains($0) } && lack.allSatisfy { !titles().contains($0) } }
        waitFor(within + 0.5, good) { ok in
            let elapsed = Date().timeIntervalSince(started)
            self.record(["notes backlinks": path, "titles": titles(), "elapsed_ms": (elapsed * 1000).rounded(), "within_ms": within * 1000,
                         "contexts": c.sidebar?.view.backlinks.links.map(\.context) ?? []], ok: ok && elapsed <= within)
            done()
        }
    }

    // MARK: tab switches

    /// Does a per-window sidebar show anything different at the moment of a tab switch? Draws the sidebar of the
    /// window about to be shown, switches, draws it again at once and after it has settled, and says where the
    /// pixels differ: only the rows whose selection changed may.
    private func probeTabSwitch(to index: Int, then done: @escaping () -> Void) {
        guard let a = notesController, let group = a.window?.tabGroup, index < group.windows.count,
              let b = group.windows[index].windowController as? EditorWindowController, a !== b,
              let sa = a.sidebar, let sb = b.sidebar, let bw = b.window else {
            record(["notes probeTabSwitch": index, "error": "no such window with a sidebar"], ok: false)
            done()
            return
        }
        a.window?.displayIfNeeded()
        let hidden = sidebarPixels(sb.view)
        let rowsA = sa.visibleRowIDs, rowsB = sb.visibleRowIDs
        let scrollA = sa.view.scroll.contentView.bounds.minY, scrollB = sb.view.scroll.contentView.bounds.minY
        let reloadsA = sa.reloads, reloadsB = sb.reloads
        let selBefore = sb.selectedRowIDs
        let t0 = CFAbsoluteTimeGetCurrent()
        group.selectedWindow = bw
        bw.makeKeyAndOrderFront(nil)
        // Before the run loop turns: what the window shows the instant it is brought forward.
        let immediate = sidebarPixels(sb.view)
        let switchMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        later(0.5) {
            bw.displayIfNeeded()
            let settled = self.sidebarPixels(sb.view)
            let selAfter = sb.selectedRowIDs
            // Rows whose look may change: those selected before or after.
            let allowed = (selBefore + selAfter).compactMap { sb.rowFrame(forID: $0) }
            let viewWidth = sb.view.bounds.width
            func outside(_ x: SidebarPixels, _ y: SidebarPixels) -> (total: Int, outside: Int) {
                // (A window that was hidden while the group was resized takes the group's size when it is
                // shown: that is AppKit's, as in a plain window, and nothing to compare pixel by pixel.)
                guard x.width == y.width, x.height == y.height else { return (0, 0) }
                var total = 0, out = 0
                let scale = Double(x.width) / Double(max(1, viewWidth))
                for py in 0..<x.height {
                    let rowStart = py * x.width * 4
                    if x.bytes[rowStart..<(rowStart + x.width * 4)] == y.bytes[rowStart..<(rowStart + x.width * 4)] { continue }
                    for px in 0..<x.width where x.bytes[rowStart + px * 4..<(rowStart + px * 4 + 4)] != y.bytes[rowStart + px * 4..<(rowStart + px * 4 + 4)] {
                        total += 1
                        let p = NSPoint(x: Double(px) / scale, y: Double(py) / scale)
                        if !allowed.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) { out += 1 }
                    }
                }
                return (total, out)
            }
            let first = outside(hidden, immediate)
            let later_ = outside(immediate, settled)
            let ok = sb.reloads == reloadsB && sa.reloads == reloadsA && rowsA == rowsB && abs(scrollA - scrollB) < 0.5
                && first.outside == 0 && later_.total == 0
            self.followSelectedTab()
            self.record(["notes probeTabSwitch": index, "switch_ms": (switchMs * 100).rounded() / 100,
                         "rows_same": rowsA == rowsB, "scroll_same": abs(scrollA - scrollB) < 0.5,
                         "reloads_on_switch": ["shown": sb.reloads - reloadsB, "left": sa.reloads - reloadsA],
                         "pixels_changed_by_switch": first.total, "pixels_changed_outside_selected_rows": first.outside,
                         "pixels_changed_after_settling": later_.total, "selected_before": selBefore, "selected_after": selAfter,
                         "window_resized_by_the_switch": hidden.width != immediate.width || hidden.height != immediate.height,
                         "same_workspace": a.workspace === b.workspace], ok: ok)
            done()
        }
    }

    struct SidebarPixels {
        var width: Int, height: Int
        var bytes: [UInt8]
    }

    func sidebarPixels(_ view: NSView) -> SidebarPixels {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return SidebarPixels(width: 0, height: 0, bytes: []) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let n = rep.bytesPerRow * rep.pixelsHigh
        var bytes = [UInt8](repeating: 0, count: n)
        if let data = rep.bitmapData { bytes.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: data, count: n) } }
        // Rows may be padded: compact them to width * 4.
        if rep.bytesPerRow != rep.pixelsWide * 4 {
            var packed: [UInt8] = []
            for y in 0..<rep.pixelsHigh { packed.append(contentsOf: bytes[(y * rep.bytesPerRow)..<(y * rep.bytesPerRow + rep.pixelsWide * 4)]) }
            bytes = packed
        }
        return SidebarPixels(width: rep.pixelsWide, height: rep.pixelsHigh, bytes: bytes)
    }

    // MARK: the palette

    func paletteStep(_ p: Any, then done: @escaping () -> Void) {
        guard let c = notesController else { record(["palette": "no window"], ok: false); done(); return }
        if let s = p as? String, s == "close" {
            c.palette?.close()
            record(["palette": "close"], ok: c.palette == nil)
            done()
            return
        }
        guard let d = p as? [String: Any], let pal = c.palette, pal.isOpen else { record(["palette": "\(p)", "error": "the palette is not open"], ok: false); done(); return }
        if let text = d["type"] as? String {
            pal.type(text)
            waitFor(5, { !pal.rows.isEmpty || d["expectEmpty"] as? Bool == true }) { ok in
                later(0.15) {
                    self.record(["palette type": text, "rows": pal.rows.map(\.title), "paths": pal.rows.map(\.detail)], ok: ok)
                    done()
                }
            }
        } else if let key = d["key"] as? String {
            switch key {
            case "down": pal.move(1)
            case "up": pal.move(-1)
            case "escape":
                _ = pal.control(pal.panel.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            default: break
            }
            record(["palette key": key, "selected": pal.panel.table.selectedRow], ok: true)
            done()
        } else if d["choose"] != nil {
            let before = c.markdownDocument
            let docs = NSDocumentController.shared.documents.count
            pal.chooseSelected(alternate: d["option"] as? Bool ?? false)
            waitFor(5, { self.notesController?.markdownDocument !== before || NSDocumentController.shared.documents.count > docs || self.window?.attachedSheet != nil }) { ok in
                later(0.3) {
                    self.followSelectedTab()
                    self.record(["palette choose": self.document?.fileURL?.lastPathComponent ?? "", "documents": NSDocumentController.shared.documents.count], ok: ok)
                    done()
                }
            }
        } else {
            record(["palette": "\(d)", "error": "unknown"], ok: false)
            done()
        }
    }

    func paletteAssertions(_ p: [String: Any]) {
        let pal = notesController?.palette
        if let open = p["open"] as? Bool { check("palette open \(open)", (pal?.isOpen ?? false) == open) }
        if let rows = p["rows"] as? [String] {
            let got = pal?.rows.map(\.title) ?? []
            check("palette rows \(rows)", Array(got.prefix(rows.count)) == rows, "\(got)")
        }
        if let first = p["first"] as? String { check("palette first row \(first)", pal?.rows.first?.title == first, "\(pal?.rows.map(\.title) ?? [])") }
        if let sel = p["selected"] as? Int { check("palette selected row \(sel)", pal?.panel.table.selectedRow == sel, "\(pal?.panel.table.selectedRow ?? -2)") }
        if let n = p["maxRows"] as? Int { check("palette lists at most \(n) rows", (pal?.rows.count ?? 0) <= n, "\(pal?.rows.count ?? 0)") }
        if let focused = p["fieldFocused"] as? Bool, let pal {
            check("palette field focused \(focused)", (pal.panel.window?.firstResponder === pal.panel.field.currentEditor()) == focused)
        }
    }

    // MARK: assertions

    func notesAssertions(_ a: [String: Any]) {
        let c = notesController, ws = c?.workspace, sb = c?.sidebar
        if let v = a["mode"] as? Bool { check("notes mode \(v)", (ws?.notesMode ?? false) == v) }
        if let v = a["sidebarShown"] as? Bool {
            let shown = sb != nil && sb?.view.window != nil && c?.notesSplit != nil && c?.window?.contentView === c?.notesContainer
            check("sidebar shown \(v)", shown == v, "sidebar \(sb != nil) split \(c?.notesSplit != nil)")
        }
        if let v = a["tabsBeginAtPane"] as? Bool, let c, let w = c.window {
            // No tab (what can be seen of it) and no click on the strip reaches left of the editor pane.
            let pane = c.root.convert(c.root.bounds, to: nil).minX
            let strip = c.tabs.strip
            let tabsLeft = strip.visibleTabFrames.filter { !$0.isEmpty }.map { strip.convert($0, to: nil).minX }.min() ?? pane
            let hitLeft = (stride(from: 70.0, to: Double(pane) - 2, by: 12.0)).contains { x in
                let hit = w.contentView?.superview?.hitTest(NSPoint(x: x, y: w.frame.height - 14))
                return hit is TabView
            }
            check("tabs begin at the editor pane \(v)", ((tabsLeft >= pane - 0.5) && !hitLeft) == v,
                  "pane \(pane), leftmost visible tab \(tabsLeft), a tab under the sidebar's title row \(hitLeft), inset \(strip.leadingInset), tabs \(strip.tabViews.count)")
        }
        if let v = a["tabInset"] as? Double, let c {
            check("tab strip starts \(v) pt in", abs(c.tabs.strip.leadingInset - CGFloat(v)) < 1, "\(c.tabs.strip.leadingInset)")
        }
        if let v = a["tabStripWidthIsTheWindows"] as? Bool, let c, let w = c.window {
            // Without a sidebar the strip fills the row between the window buttons and the trailing edge, as before.
            let strip = c.tabs.strip
            let whole = abs(strip.frame.width - (w.frame.width - TabStripController.leadingClearance - TabStripController.trailingClearance)) < 1
            check("tab strip has the whole row \(v)", (whole && strip.leadingInset == 0) == v, "width \(strip.frame.width) window \(w.frame.width) inset \(strip.leadingInset)")
        }
        if let v = a["sidebarOpaque"] as? Bool, let sb {
            // Not faded and not hidden, whatever the chrome is doing.
            var hiddenAbove = false
            var view: NSView? = sb.view
            while let x = view { if x.isHidden || x.alphaValue < 0.99 { hiddenAbove = true }; view = x.superview }
            check("sidebar fully visible \(v)", !hiddenAbove == v, "alpha \(sb.view.alphaValue)")
        }
        if let v = a["plainLayout"] as? Bool, let c {
            // Plain mode: the editor's own view is the window's content, nothing else is there.
            let plain = c.window?.contentView === c.root && c.sidebar == nil && c.notesSplit == nil
            check("plain layout \(v)", plain == v, "content \(String(describing: c.window?.contentView.map { "\(Swift.type(of: $0))" }))")
        }
        if let rows = a["rows"] as? [String] { check("sidebar rows \(rows)", sb?.visibleRowTitles == rows, "\(sb?.visibleRowTitles ?? [])") }
        if let rows = a["rowsStart"] as? [String] {
            let got = sb?.visibleRowTitles ?? []
            check("sidebar rows start \(rows)", Array(got.prefix(rows.count)) == rows, "\(got)")
        }
        if let rows = a["rowsContain"] as? [String] {
            let got = sb?.visibleRowTitles ?? []
            check("sidebar shows \(rows)", rows.allSatisfy(got.contains), "\(got)")
        }
        if let rows = a["rowsLack"] as? [String] {
            let got = sb?.visibleRowTitles ?? []
            check("sidebar does not show \(rows)", rows.allSatisfy { !got.contains($0) }, "\(got)")
        }
        if let ids = a["selected"] as? [String] {
            check("sidebar selection \(ids)", sb?.selectedRowIDs == ids.map(nodeID), "\(sb?.selectedRowIDs ?? [])")
        }
        if let tags = a["tags"] as? [String] {
            let got = (ws?.snapshot.tags ?? []).map { "\($0.tag)=\($0.count)" }
            check("tags contain \(tags)", tags.allSatisfy(got.contains), "\(got)")
        }
        if let tags = a["selectedTags"] as? [String] { check("tag filter \(tags)", ws?.selectedTags == tags, "\(ws?.selectedTags ?? [])") }
        if let hits = a["hits"] as? [String] {
            let got = (ws?.snapshot.hits ?? []).map(\.title)
            check("search hits \(hits)", got == hits, "\(got)")
        }
        if let hits = a["hitsContain"] as? [String] {
            let got = (ws?.snapshot.hits ?? []).map(\.title)
            check("search hits contain \(hits)", hits.allSatisfy(got.contains), "\(got)")
        }
        if let n = a["hitCount"] as? Int { check("hit count \(n)", ws?.snapshot.hits.count == n, "\(ws?.snapshot.hits.count ?? -1)") }
        if let titles = a["backlinks"] as? [String] {
            let got = c?.sidebar?.view.backlinks.links.map(\.fromTitle) ?? []
            check("backlinks \(titles)", got == titles, "\(got)")
        }
        if let titles = a["backlinksContain"] as? [String] {
            let got = c?.sidebar?.view.backlinks.links.map(\.fromTitle) ?? []
            check("backlinks contain \(titles)", titles.allSatisfy(got.contains), "\(got)")
        }
        if let v = a["backlinksShown"] as? Bool { check("backlinks panel shown \(v)", (sb?.view.showsBacklinks ?? false) == v && (ws?.backlinksShown ?? false) == v) }
        if let v = a["renaming"] as? Bool { check("renaming \(v)", (sb?.isRenaming ?? false) == v) }
        if let v = a["sort"] as? String { check("sort \(v)", ws?.sort.rawValue == v, ws?.sort.rawValue ?? "") }
        if let v = a["sameWorkspace"] as? Bool, let c {
            let others = (c.window?.tabGroup?.windows ?? []).compactMap { ($0.windowController as? EditorWindowController)?.workspace }
            let same = !others.isEmpty && others.allSatisfy { $0 === c.workspace }
            check("one workspace for the tab group \(v)", same == v, "\(others.count) windows")
        }
        if let v = a["sidebarWidth"] as? Double, let sb {
            check("sidebar width \(v)", abs(sb.view.frame.width - v) < 1.5, "\(sb.view.frame.width)")
        }
        if let v = a["backlinksSidebarsSharePosition"] as? Bool, v {
            let ys = (c?.window?.tabGroup?.windows ?? []).compactMap { ($0.windowController as? EditorWindowController)?.sidebar?.view.scroll.contentView.bounds.minY }
            check("sidebars of the group are scrolled alike", Set(ys.map { ($0 * 2).rounded() }).count <= 1, "\(ys)")
        }
        if let f = a["file"] as? [String: Any], let root = ws?.primaryRoot, let path = f["path"] as? String {
            let url = root.url.appendingPathComponent(expandVars(path))
            let exists = FileManager.default.fileExists(atPath: url.path)
            if let want = f["exists"] as? Bool { check("file \(path) exists \(want)", exists == want, url.path) }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if let v = f["contains"] as? String { check("file \(path) contains \(v)", text.contains(expandVars(v)), text) }
            if let v = f["lacks"] as? String { check("file \(path) lacks \(v)", !text.contains(expandVars(v)), text) }
            if let v = f["equals"] as? String { check("file \(path) equals", text == expandVars(v), text) }
        }
        if let f = a["folder"] as? [String: Any], let root = ws?.primaryRoot, let path = f["path"] as? String {
            let dir = root.url.appendingPathComponent(path)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            if let n = f["count"] as? Int { check("folder \(path) holds \(n) item(s)", names.count == n, "\(names)") }
            if let want = f["contains"] as? [String] { check("folder \(path) contains \(want)", want.allSatisfy { names.contains(expandVars($0)) }, "\(names)") }
        }
        if let v = a["trashed"] as? Bool { check("moved to the Trash \(v)", (lastTrashed?.landed == true && lastTrashed?.original == false) == v, "\(String(describing: lastTrashed))") }
        if let v = a["library"] as? [String: Any] {
            if let n = v["noteCount"] as? Int { check("library holds \(n) note(s)", ws?.snapshot.noteCount == n, "\(ws?.snapshot.noteCount ?? -1)") }
            if let roots = v["roots"] as? [String] { check("library roots \(roots)", ws?.snapshot.roots.map(\.name) == roots, "\(ws?.snapshot.roots.map(\.name) ?? [])") }
            if v["offMainThread"] != nil { check("the library never worked on the main thread", ws?.library.isIdle == true) }
        }
        if let ids = a["revealed"] as? [String], let sb { check("rows revealed \(ids)", ids.allSatisfy { sb.item(withID: nodeID($0)) != nil && sb.rowFrame(forID: nodeID($0)) != nil }) }
        if let t = a["title"] as? String, let w = window { check("window title \(t)", TabStripModel.title(of: w) == t, TabStripModel.title(of: w)) }
        if let v = a["externalOpened"] as? String { check("opened outside notes mode: \(v)", Self.opened?.lastPathComponent == v, Self.opened?.lastPathComponent ?? "nil") }
        if let v = a["documentURLEndsWith"] as? String {
            let got = notesController?.markdownDocument?.fileURL?.path ?? ""
            check("front document is \(v)", got.hasSuffix(expandVars(v)), got)
        }
        if let v = a["openDocuments"] as? [String] {
            let names = NSDocumentController.shared.documents.compactMap { $0.fileURL?.lastPathComponent }.sorted()
            check("open documents \(v)", names == v.sorted(), "\(names)")
        }
        if let v = a["quiet"] as? Bool, v, let ws { check("library settled", libraryQuiet(ws), "idle \(ws.library.isIdle)") }
    }
}
#endif
