import AppKit
import UniformTypeIdentifiers
import MarkdownCore

/// The formats File > Export writes besides PDF. Every one is rendered by the core from its own `Document`, never read
/// back from the text view, so nothing the editor paints (authorship colours, focus dimming) and nothing the file
/// carries (the annotation block) can reach it. The shell reads the pictures and writes the file.
public enum ExportFormat: CaseIterable, Sendable {
    case html, word, plainText, markdown

    public var fileExtension: String {
        switch self {
        case .html: return "html"
        case .word: return "docx"
        case .plainText: return "txt"
        case .markdown: return "md"
        }
    }

    public var contentType: UTType {
        switch self {
        case .html: return .html
        case .word: return UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx") ?? .data
        case .plainText: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        }
    }

    /// What a failed export of the file named `name` calls it ("The PDF", "The Word document").
    static func subject(ofFileNamed name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "The HTML file"
        case "docx": return "The Word document"
        case "txt": return "The text file"
        case "md", "markdown": return "The Markdown file"
        default: return "The PDF"
        }
    }
}

/// The pictures a document refers to, read for an export through the same seam as the preview's.
enum ExportPictures {
    /// The bytes and type of every local picture among `destinations` that can be read (a remote one, or one that cannot
    /// be read, is left out and stays as written), and their sizes in points as the preview has them.
    static func load(_ destinations: Set<String>, documentURL: URL?) -> (data: [ImageData], sizes: [ImageSize]) {
        let sizes = PictureSizes().sizes(for: destinations, documentURL: documentURL)
        var data: [ImageData] = []
        for destination in destinations.sorted() {
            guard let file = DocumentFileAccess.pictureURL(for: destination, documentURL: documentURL), file.isFileURL,
                  DocumentFileAccess.mayRead(file, documentURL: documentURL), let bytes = try? DocumentFileAccess.read(file) else { continue }
            data.append(ImageData(destination: destination, mime: mime(of: bytes, file: file), bytes: bytes))
        }
        return (data, sizes)
    }

    /// The picture's own type from its bytes, else from its file name.
    static func mime(of bytes: Data, file: URL) -> String {
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil), let id = CGImageSourceGetType(source),
           let mime = UTType(id as String)?.preferredMIMEType { return mime }
        return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

extension MarkdownDocument {
    /// One self-contained HTML file: the core's standalone page with the document's template inlined, in the Light theme (the
    /// printed look) and the editor's type, and the local pictures embedded as `data:` URIs. The bundled fonts' `@font-face`
    /// rules are left out (they point at the app's own scheme); the family names stay in the stacks, so a reader without
    /// the fonts gets the stack's fallbacks. `completion` runs once, on the main thread.
    @MainActor
    public func exportHTML(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        let appearance = session.appearance
        let typography = PreviewTypography.make(from: appearance)
        let light = themeById(id: "light") ?? builtinThemes()[0]
        let template = session.resolvedTemplate(frontMatterName: session.frontMatterTemplateName()).template
        let css = TemplateStore.shared.css(for: template, theme: light, typography: typography)
        let title = displayName ?? "Untitled"
        runExport(to: url, pictures: true, completion: completion) { doc, pictures, sizes in
            let options = RenderOptions(sourceLines: false, standalone: true, sanitize: false, highlight: true, fallbackTitle: title,
                                        style: PreviewStyle(theme: light, typography: typography), imageSizes: sizes, imageData: pictures)
            return Data(TemplateStore.replacingStyle(inPage: doc.renderHtml(options: options), with: css).utf8)
        }
    }

    /// A `.docx` the core writes, styled by the document's template and the editor's type, on the document's paper.
    @MainActor
    public func exportWord(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        let spec = session.resolvedTemplate(frontMatterName: session.frontMatterTemplateName()).template.spec
        let typography = PreviewTypography.makeForWord(from: session.appearance)
        let paper = printInfo.paperSize
        let title = displayName ?? "Untitled"
        runExport(to: url, pictures: true, completion: completion) { doc, pictures, sizes in
            doc.renderDocx(options: DocxOptions(title: title, spec: spec, typography: typography, imageSizes: sizes, imageData: pictures,
                                                pageWidthPt: Double(paper.width), pageHeightPt: Double(paper.height)))
        }
    }

    /// The text a reader would want, UTF-8 without a byte order mark and with `\n` line endings.
    @MainActor
    public func exportPlainText(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        runExport(to: url, pictures: false, completion: completion) { doc, _, _ in Data(doc.renderPlain().utf8) }
    }

    /// The Markdown as written, without the annotation block (the session's text never has it) and, unless
    /// `keepFrontMatter`, without the front matter. Nothing is reformatted; the line endings and the byte order mark are the
    /// document's.
    @MainActor
    public func exportMarkdown(to url: URL, keepFrontMatter: Bool = true, completion: @escaping @MainActor (Error?) -> Void) {
        let (bom, ending) = (hasBOM, lineEnding)
        runExport(to: url, pictures: false, completion: completion) { doc, _, _ in
            TextCodec.encode(keepFrontMatter ? doc.text() : doc.textWithoutFrontMatter(), hasBOM: bom, lineEnding: ending)
        }
    }

    /// The common path: the pictures are read on a utility queue (their names come from the core first), `render` runs on the
    /// session's analysis queue, where the core document lives, and the file is written on a utility queue. A destination
    /// that cannot be written is reported before any of it. `completion` runs once, on the main thread.
    @MainActor
    private func runExport(to url: URL, pictures: Bool, completion: @escaping @MainActor (Error?) -> Void,
                           render: @escaping (Document, [ImageData], [ImageSize]) -> Data) {
        if let problem = ExportError.destinationProblem(url) {
            completion(problem)
            return
        }
        // As for the PDF: the system may end the app at once at log-out or when it has nothing on screen, and the window may
        // be closed while the export runs.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: "Exporting a document")
        Self.exportsInFlight += 1
        let coordinator = session.coordinator
        let documentURL = fileURL

        let write: @Sendable (Data) -> Void = { data in
            DispatchQueue.global(qos: .utility).async {
                var failure: Error?
                do { try DocumentFileAccess.write(data, to: url) } catch { failure = error }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.exportsInFlight -= 1
                        ProcessInfo.processInfo.endActivity(activity)
                        completion(failure)
                    }
                }
            }
        }
        let renderThenWrite: @Sendable ([ImageData], [ImageSize]) -> Void = { data, sizes in
            coordinator.async({ doc in render(doc, data, sizes) }) { bytes, _ in write(bytes) }
        }
        guard pictures else { renderThenWrite([], []); return }
        coordinator.async({ doc in Set(doc.images().map(\.destination)) }) { destinations, _ in
            DispatchQueue.global(qos: .utility).async {
                let (data, sizes) = ExportPictures.load(destinations, documentURL: documentURL)
                renderThenWrite(data, sizes)
            }
        }
    }
}
