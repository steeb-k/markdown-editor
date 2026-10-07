import AppKit
import MarkdownCore

/// What a rename of a template does to the documents that name it (PLAN 3.22).
extension TemplateEditor {
    /// Finds the open documents and the library's notes whose front matter names `old` (compared as `TemplateStore.key`
    /// does) and, when there are any, asks whether they should name `new` instead; Update writes the library's edits the
    /// way a note rename does and sets the template of the open documents outside the library. `done` runs once the
    /// documents are changed, or at once when nothing is asked or the answer is Leave.
    func offerTemplateUpdate(from old: String, to new: String, library: LibraryController? = nil, workspace: Workspace? = nil,
                             done: @escaping () -> Void = {}) {
        let key = TemplateStore.key(old)
        let library = library ?? Workspace.libraryController(for: Settings.shared)
        let workspace = workspace
            ?? NSApp.windows.lazy.compactMap { ($0.windowController as? EditorWindowController)?.workspace }.first
            ?? Workspace.make(settings: .shared, notesMode: false)
        // The library hears what is on screen first, so what it answers is what the documents hold.
        let texts = workspace.flushOpenDocuments()
        let open = Workspace.markdownDocuments().filter { $0.session.frontMatterTemplateName().map(TemplateStore.key) == key }
        let strays = open.filter { doc in doc.fileURL.flatMap { library.ref(for: $0) } == nil }
        library.templateEdits(from: old, to: new) { [weak self] edits in
            let count = Set(edits.map(\.note)).count + strays.count
            guard count > 0 else { done(); return }
            let question = "Update \(count) document\(count == 1 ? "" : "s") that \(count == 1 ? "uses" : "use") \u{201C}\(old)\u{201D}?"
            WorkspacePrompts.confirmTemplateUpdate(question: question, newName: new, window: self?.hostWindow) { update in
                guard update else { done(); return }
                workspace.applyEdits(edits, texts: texts, window: self?.hostWindow, actionName: "Change Template",
                                     failure: "Some documents could not be updated") { touched in
                    // An open note was written through its document; the strays have no note to be written to.
                    for doc in strays where doc.session.frontMatterTemplateName().map(TemplateStore.key) == key {
                        doc.session.setTemplate(name: new)
                    }
                    workspace.flushOpenDocuments()
                    library.refresh(touched)
                    done()
                }
            }
        }
    }
}
