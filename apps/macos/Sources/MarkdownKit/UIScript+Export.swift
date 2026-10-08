#if DEBUG || UI_SCRIPT
import AppKit

/// The harness's steps for File > Export (HTML, Word, plain text and Markdown; the PDF has its own step, `exportPDF`) and its
/// assertions on what they wrote: a file's text and size, and the parts of a `.docx`. The save panel is the system's, so the
/// step calls the document's own export method, as the menu item's action does after the panel.
extension UIScriptRunner {
    /// A path of the script as a file in the output directory: `out:name` or `name`.
    private func outFile(_ path: String) -> URL {
        outDir.appendingPathComponent(path.hasPrefix("out:") ? String(path.dropFirst(4)) : path)
    }

    /// `{"export": {"format": "html"|"docx"|"text"|"markdown", "to": "out:name", "keepFrontMatter": false}}`
    func exportStep(_ s: [String: Any], then done: @escaping () -> Void) {
        guard let doc = document, let format = s["format"] as? String, let to = s["to"] as? String else {
            record(["export": s, "error": "needs a document, a format and a destination"], ok: false)
            done()
            return
        }
        let url = outFile(to)
        try? FileManager.default.removeItem(at: url)
        let t0 = CFAbsoluteTimeGetCurrent()
        let finished: @MainActor (Error?) -> Void = { error in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            self.record(["export": format, "to": to, "bytes": bytes, "ms": (CFAbsoluteTimeGetCurrent() - t0) * 1000, "error": error.map { "\($0)" } ?? ""],
                        ok: error == nil && FileManager.default.fileExists(atPath: url.path))
            done()
        }
        switch format {
        case "html": doc.exportHTML(to: url, completion: finished)
        case "docx": doc.exportWord(to: url, completion: finished)
        case "text": doc.exportPlainText(to: url, completion: finished)
        case "markdown": doc.exportMarkdown(to: url, keepFrontMatter: (s["keepFrontMatter"] as? Bool) ?? true, completion: finished)
        default:
            record(["export": s, "error": "unknown format"], ok: false)
            done()
        }
    }

    /// `{"file": {"path": "out:name", "contains": [...], "lacks": [...], "sizeOver": n, "equals": "..."}}`: a file in the output
    /// directory, read as UTF-8 text. `contains` and `lacks` take a string or a list of them.
    func exportFileAssertions(_ f: [String: Any]) {
        // (Without a path it is the open document's file on disk, which `assertions` reads.)
        guard let path = f["path"] as? String else { return }
        let url = outFile(path)
        let data = try? Data(contentsOf: url)
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        func list(_ key: String) -> [String] { (f[key] as? [String]) ?? (f[key] as? String).map { [$0] } ?? [] }
        if let want = f["exists"] as? Bool { check("file \(path) exists \(want)", (data != nil) == want) }
        if let n = f["sizeOver"] as? Int { check("file \(path) is over \(n) bytes", (data?.count ?? 0) > n, "\(data?.count ?? -1)") }
        if let v = f["equals"] as? String { check("file \(path) equals", text == v, String(text.prefix(300))) }
        for needle in list("contains") { check("file \(path) contains \(needle.debugDescription)", text.contains(needle), String(text.prefix(300))) }
        for needle in list("lacks") { check("file \(path) lacks \(needle.debugDescription)", !text.contains(needle), "") }
    }

    /// `{"docx": {"path": "out:name.docx", "documentContains": [...], "documentLacks": [...], "styles": ["Heading1", ...],
    /// "stylesContain": [...], "parts": ["word/footnotes.xml", ...], "mediaCount": n}}`: the package unzipped with `ditto -x -k`
    /// beside the file; every XML part must parse.
    func docxAssertions(_ d: [String: Any]) {
        guard let path = d["path"] as? String else { check("docx assertion needs a path", false); return }
        let file = outFile(path)
        let folder = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".unzipped")
        try? FileManager.default.removeItem(at: folder)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", file.path, folder.path]
        ditto.standardError = FileHandle.nullDevice
        try? ditto.run()
        ditto.waitUntilExit()
        check("docx \(path) unzips", ditto.terminationStatus == 0, "ditto \(ditto.terminationStatus)")
        guard ditto.terminationStatus == 0 else { return }

        func part(_ name: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func list(_ key: String) -> [String] { (d[key] as? [String]) ?? (d[key] as? String).map { [$0] } ?? [] }
        let parts = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/footnotes.xml",
                     "word/settings.xml", "word/_rels/document.xml.rels"]
        for name in parts {
            let data = (try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data()
            let parser = XMLParser(data: data)
            check("docx part \(name) is well formed", !data.isEmpty && parser.parse(), parser.parserError.map { "\($0)" } ?? "empty")
        }
        let document = part("word/document.xml"), styles = part("word/styles.xml")
        for needle in list("documentContains") { check("docx document contains \(needle.debugDescription)", document.contains(needle), String(document.prefix(300))) }
        for needle in list("documentLacks") { check("docx document lacks \(needle.debugDescription)", !document.contains(needle), "") }
        for id in list("styles") { check("docx defines style \(id)", styles.contains("w:styleId=\"\(id)\""), "") }
        for needle in list("stylesContain") { check("docx styles contain \(needle.debugDescription)", styles.contains(needle), "") }
        for name in list("parts") {
            check("docx has part \(name)", FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "")
        }
        if let n = d["mediaCount"] as? Int {
            let media = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("word/media").path)) ?? []
            check("docx holds \(n) picture(s)", media.count == n, "\(media)")
        }
    }
}
#endif
