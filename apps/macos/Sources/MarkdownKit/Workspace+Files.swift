import AppKit
import MarkdownCore

/// A note to open, and where the caret goes in it (a template's `{{cursor}}`).
public struct NoteOpenRequest: Equatable {
    public var url: URL
    public var cursor: Int?
}

public enum LinkUpdateAnswer { case update, leave, cancel }

/// The questions the file operations ask. Sheets on the window the user is working in; tests answer
/// through the hooks.
public enum WorkspacePrompts {
    nonisolated(unsafe) public static var linkUpdateOverride: ((String) -> LinkUpdateAnswer)?
    nonisolated(unsafe) public static var trashEditedOverride: ((String) -> Bool)?

    static func confirmLinkUpdate(_ question: String, window: NSWindow?, completion: @escaping (LinkUpdateAnswer) -> Void) {
        if let hook = linkUpdateOverride { completion(hook(question)); return }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "Notes that link to this one by name will point at the new name."
        alert.addButton(withTitle: "Update Links")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Rename Only")
        present(alert, on: window) { r in
            completion(r == .alertFirstButtonReturn ? .update : r == .alertThirdButtonReturn ? .leave : .cancel)
        }
    }

    static func confirmTrashEdited(_ names: String, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        if let hook = trashEditedOverride { completion(hook(names)); return }
        let alert = NSAlert()
        alert.messageText = "\(names) has changes that were not saved"
        alert.informativeText = "Moving it to the Trash discards them."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: window) { completion($0 == .alertFirstButtonReturn) }
    }

    static func report(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        present(alert, on: window) { _ in }
    }

    private static func present(_ alert: NSAlert, on window: NSWindow?, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}

extension Workspace {
    // MARK: open documents

    static func markdownDocuments() -> [MarkdownDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
    }

    /// Open documents of the files at or below `url`.
    static func openDocuments(at url: URL) -> [MarkdownDocument] {
        let base = DocumentFileAccess.canonical(url).path
        return markdownDocuments().filter {
            guard let f = $0.fileURL.map({ DocumentFileAccess.canonical($0).path }) else { return false }
            return f == base || f.hasPrefix(base + "/")
        }
    }

    /// Tells the library the text of every open document that lies in a root (so that what it
    /// answers next reflects what is on screen, saved or not). Returns the text each was given.
    @discardableResult
    func flushOpenDocuments() -> [String: String] {
        var texts: [String: String] = [:]
        for doc in Self.markdownDocuments() {
            guard let url = doc.fileURL, let ref = library.ref(for: url) else { continue }
            let text = doc.session.text
            library.push(ref, text: text)
            texts[DocumentFileAccess.canonical(url).path] = text
            cancelPush(for: url)
        }
        return texts
    }

    // MARK: pushing an open document's text

    /// An edit of an open document that lies in a root: its text reaches the library at most a
    /// second later (half a second after the last keystroke of a burst).
    public func documentEdited(_ doc: MarkdownDocument) {
        guard let url = doc.fileURL else { return }
        let key = DocumentFileAccess.canonical(url).path
        let now = Date()
        var state = pushes[key] ?? PushState(first: now, item: nil)
        state.item?.cancel()
        let delay = min(Self.pushDelay, max(0, Self.pushLimit - now.timeIntervalSince(state.first)))
        let item = DispatchWorkItem { [weak self, weak doc] in
            guard let self else { return }
            pushes[key] = nil
            guard let doc, let url = doc.fileURL, let ref = library.ref(for: url) else { return }
            library.push(ref, text: doc.session.text)
        }
        state.item = item
        pushes[key] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancelPush(for url: URL) {
        let key = DocumentFileAccess.canonical(url).path
        pushes[key]?.item?.cancel()
        pushes[key] = nil
    }

    /// A document that was edited closed without saving: what is on disk is the truth again.
    public func documentClosed(url: URL, wasEdited: Bool) {
        cancelPush(for: url)
        if wasEdited { library.refresh([url], force: true) }
    }

    // MARK: making things

    private func folderURL(_ folder: LibraryNode?) throws -> URL {
        guard let url = (folder ?? destinationFolder())?.url else { throw CocoaError(.fileNoSuchFile) }
        return url
    }

    /// A new, empty note called `base.md` (numbered when the name is taken) in a folder.
    public func createNote(in folder: LibraryNode? = nil, base: String = "Untitled", text: String = "") throws -> URL {
        let dir = try folderURL(folder)
        let url = try DocumentFileAccess.writeNew(Data(text.utf8), in: dir, name: base, ext: "md")
        library.refresh([url])
        return url
    }

    public func createFolder(in folder: LibraryNode? = nil, base: String = "New Folder") throws -> URL {
        let dir = try folderURL(folder)
        let url = DocumentFileAccess.uniqueName(in: dir, base: base, ext: "")
        try DocumentFileAccess.createDirectory(url)
        library.refresh([url])
        return url
    }

    /// `Name 2.md` beside `Name.md`.
    public func duplicate(_ node: LibraryNode) throws -> URL {
        let dir = node.url.deletingLastPathComponent()
        let stem = node.url.deletingPathExtension().lastPathComponent
        let target = DocumentFileAccess.uniqueName(in: dir, base: node.kind == .folder ? node.url.lastPathComponent : stem,
                                                   ext: node.kind == .folder ? "" : node.url.pathExtension)
        // A document with unsaved changes duplicates as it is on disk: the copy is of the file.
        try DocumentFileAccess.copy(node.url, to: target)
        library.refresh([target])
        return target
    }

    /// Templates are the notes in the templates folder of the library.
    public var templatesFolder: URL? {
        primaryRoot?.url.appendingPathComponent(settings.templatesFolder, isDirectory: true)
    }

    public func templates() -> [URL] {
        templatesFolder.map(NoteTemplates.list(in:)) ?? []
    }

    /// A new note in `folder` made from a template: named after it (numbered when taken), with
    /// the placeholders filled in and the caret where `{{cursor}}` was.
    public func newNote(fromTemplate template: URL, in folder: LibraryNode? = nil, date: Date = Date()) throws -> NoteOpenRequest {
        let dir = try folderURL(folder)
        let base = template.deletingPathExtension().lastPathComponent
        let source = NoteText.decode(try DocumentFileAccess.read(template)) ?? ""
        // The title the note will have is its file name, so the name is chosen first.
        let ext = template.pathExtension.isEmpty ? "md" : template.pathExtension
        let target = DocumentFileAccess.uniqueName(in: dir, base: base, ext: ext)
        let expanded = NoteTemplates.expand(source, title: target.deletingPathExtension().lastPathComponent, date: date,
                                            dailyFormat: settings.dailyFormat)
        let url = try DocumentFileAccess.writeNew(Data(expanded.text.utf8), in: dir, name: target.deletingPathExtension().lastPathComponent, ext: ext)
        library.refresh([url])
        return NoteOpenRequest(url: url, cursor: Int(expanded.cursor))
    }

    /// Where today's note is, and whether it had to be made: `Daily/YYYY-MM-DD.md` in the library,
    /// from `Templates/Daily.md` when there is one. Made once; later calls find it.
    public func todaysNote(date: Date = Date()) throws -> NoteOpenRequest {
        guard let root = primaryRoot else { throw CocoaError(.fileNoSuchFile) }
        let folder = root.url.appendingPathComponent(settings.dailyFolder, isDirectory: true)
        let name = DailyNote.name(for: date, format: settings.dailyFormat)
        let url = folder.appendingPathComponent(name).appendingPathExtension("md")
        if DocumentFileAccess.exists(url) { return NoteOpenRequest(url: url, cursor: nil) }
        try DocumentFileAccess.ensureFolder(folder)
        var text = ""
        var cursor: Int?
        if let template = templatesFolder?.appendingPathComponent("Daily.md"), DocumentFileAccess.exists(template),
           let source = NoteText.decode(try DocumentFileAccess.read(template)) {
            let expanded = NoteTemplates.expand(source, title: name, date: date, dailyFormat: settings.dailyFormat)
            text = expanded.text
            cursor = Int(expanded.cursor)
        }
        // Never over a note another call made in the meantime.
        let made = try DocumentFileAccess.writeNew(Data(text.utf8), in: folder, name: name, ext: "md")
        guard made == url else { return NoteOpenRequest(url: made, cursor: cursor) }
        library.refresh([url])
        return NoteOpenRequest(url: url, cursor: cursor)
    }

    // MARK: renaming and moving

    /// Moves `old` to `new` (a rename is a move within a folder). When notes link to what moves, asks
    /// whether to update the links, and updates them (through the open documents, each as one
    /// undoable change, and through file coordination for the rest) before the file moves.
    /// `completion` gets the new location, nil when the user cancelled.
    public func move(_ old: URL, to new: URL, window: NSWindow?, completion: @escaping (Result<URL?, Error>) -> Void) {
        let caseOnly = old.path.lowercased() == new.path.lowercased()
        if DocumentFileAccess.canonical(old) == Self.canonicalPlace(new) { completion(.success(nil)); return }
        if DocumentFileAccess.exists(new), !caseOnly {
            completion(.failure(CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: new.path])))
            return
        }
        let texts = flushOpenDocuments()
        let pairs = movedNotes(from: old, to: new)
        collectEdits(pairs) { [self] edits in
            let finish: ([LibraryEdit]) -> Void = { [self] applied in
                var touched: [URL] = []
                if !applied.isEmpty { touched = applyEdits(applied, texts: texts, window: window) }
                do {
                    try DocumentFileAccess.move(old, to: new)
                } catch {
                    library.refresh(touched)
                    completion(.failure(error))
                    return
                }
                library.moved(from: old, to: new)
                library.refresh(touched.filter { Self.canonicalPlace($0) != DocumentFileAccess.canonical(old) })
                completion(.success(new))
            }
            guard !edits.isEmpty else { finish([]); return }
            WorkspacePrompts.confirmLinkUpdate(NoteNaming.linkUpdateQuestion(edits), window: window) { answer in
                switch answer {
                case .update: finish(edits)
                case .leave: finish([])
                case .cancel: completion(.success(nil))
                }
            }
        }
    }

    /// The URL of something that may not exist yet, with symbolic links in its folder resolved.
    static func canonicalPlace(_ url: URL) -> URL {
        DocumentFileAccess.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }

    /// What moves with `old` and where it goes, as library references (a note, or a folder with its
    /// notes). Empty when either end is outside the roots: nothing links across that.
    private func movedNotes(from old: URL, to new: URL) -> [(NoteRef, NoteRef)] {
        guard let from = library.ref(for: old), let to = library.ref(for: Self.canonicalPlace(new)), !from.path.isEmpty, !to.path.isEmpty else { return [] }
        return [(from, to)]
    }

    private func collectEdits(_ pairs: [(NoteRef, NoteRef)], completion: @escaping ([LibraryEdit]) -> Void) {
        guard let (from, to) = pairs.first else { completion([]); return }
        let isFolder = library.url(for: from).map(DocumentFileAccess.isDirectory) ?? false
        guard isFolder else {
            library.renameEdits(from: from, to: to, completion: completion)
            return
        }
        library.notes(under: from.path, root: from.root) { [self] notes in
            var all: [LibraryEdit] = []
            func next(_ i: Int) {
                guard i < notes.count else { completion(all); return }
                let n = notes[i]
                let moved = NoteRef(root: to.root, path: to.path + n.path.dropFirst(from.path.count))
                library.renameEdits(from: n, to: moved) { edits in
                    all.append(contentsOf: edits)
                    next(i + 1)
                }
            }
            next(0)
        }
    }

    /// Writes the edits into the notes they are for: open ones through their sessions, the rest
    /// through file coordination. Returns the files of the closed notes it changed.
    private func applyEdits(_ edits: [LibraryEdit], texts: [String: String], window: NSWindow?) -> [URL] {
        var order: [NoteRef] = []
        var byNote: [NoteRef: [LibraryEdit]] = [:]
        for e in edits {
            if byNote[e.note] == nil { order.append(e.note) }
            byNote[e.note, default: []].append(e)
        }
        var changed: [URL] = []
        var failed: [String] = []
        for note in order {
            guard let url = library.url(for: note), let list = byNote[note] else { continue }
            if let doc = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
                let key = DocumentFileAccess.canonical(url).path
                if let was = texts[key], was == doc.session.text, doc.session.applyLinkEdits(list) { continue }
                failed.append(url.lastPathComponent)
                continue
            }
            do {
                let data = try DocumentFileAccess.readCoordinated(url)
                guard let text = NoteText.decode(data), let edited = NoteText.apply(list, to: text),
                      let out = NoteText.encode(edited, replacing: data) else { failed.append(url.lastPathComponent); continue }
                try DocumentFileAccess.writeCoordinated(out, to: url)
                changed.append(url)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            let info = [NSLocalizedDescriptionKey: "Some links could not be updated", NSLocalizedRecoverySuggestionErrorKey: failed.joined(separator: ", ")]
            WorkspacePrompts.report(NSError(domain: "Markdown", code: 1, userInfo: info), window: window)
        }
        return changed
    }

    // MARK: trash

    /// Moves files and folders to the Trash (never unlinks them). Documents open on them close; one
    /// with unsaved changes asks first. `completion` gets how many went.
    public func trash(_ urls: [URL], window: NSWindow?, completion: @escaping (Int) -> Void) {
        let docs = urls.flatMap { Self.openDocuments(at: $0) }
        let edited = docs.filter(\.isDocumentEdited)
        let go = { [self] in
            var count = 0
            for doc in docs {
                doc.updateChangeCount(.changeCleared)
                if let url = doc.fileURL { cancelPush(for: url) }
                doc.close()
            }
            for url in urls {
                do { try DocumentFileAccess.trash(url); count += 1 } catch { WorkspacePrompts.report(error, window: window) }
            }
            library.refresh(urls)
            completion(count)
        }
        guard !edited.isEmpty else { go(); return }
        let names = edited.map { "\u{201C}\($0.displayName ?? "Untitled")\u{201D}" }.joined(separator: ", ")
        WorkspacePrompts.confirmTrashEdited(names, window: window) { ok in
            if ok { go() } else { completion(0) }
        }
    }

    // MARK: files from Finder

    /// Copies files dropped from elsewhere into `folder`, under unused names. The copying is done off the
    /// main thread (a dropped folder can be big); `completion` gets the new items.
    public func copyIn(_ urls: [URL], to folder: URL, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var made: [URL] = []
            for src in urls {
                let isDir = DocumentFileAccess.isDirectory(src)
                let target = DocumentFileAccess.uniqueName(in: folder, base: isDir ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent,
                                                           ext: isDir ? "" : src.pathExtension)
                if (try? DocumentFileAccess.copy(src, to: target)) != nil { made.append(target) }
            }
            DispatchQueue.main.async { [self] in
                library.refresh(made)
                completion(made)
            }
        }
    }
}
