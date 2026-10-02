import Foundation

/// Every read and write of document content goes through here. Trivial today; it is the seam
/// where App Store sandboxing later adds security-scoped bookmarks and one-time folder grants.
public enum DocumentFileAccess {
    public static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    // MARK: pictures: one rule for the editor, the preview, PDF and print

    /// The schemes a picture is fetched from over the network (by the editor's `ImageController`
    /// through URLSession, by the preview's web view itself). Both are subject to the same App
    /// Transport Security settings in Info.plist, so they load the same remote pictures.
    public static let remotePictureSchemes: Set<String> = ["http", "https"]

    /// Where the picture a Markdown document names (`![](destination)`, or an `<img src>`) is:
    /// an `http(s)` URL, a `data:` URL, or a file (a `file:` URL, an absolute path, `~/`, or a path
    /// relative to the document's folder, `..` included). Nil when it cannot be resolved (a
    /// relative path in a document never saved, another scheme). Percent-escapes in a path are
    /// decoded once, so the destination as written and the same destination as an escaped `src`
    /// attribute give the same file.
    ///
    /// The editor (`ImageController`) and the preview, PDF and print (`PreviewSchemeHandler`)
    /// both ask here and then `mayRead`, so they show the same pictures.
    public static func pictureURL(for destination: String, documentURL: URL?) -> URL? {
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        if let colon = d.firstIndex(of: ":"), d[..<colon].count > 1, d[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
            guard let url = URL(string: d) ?? URL(string: d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return nil }
            switch url.scheme?.lowercased() {
            case let s? where remotePictureSchemes.contains(s): return url
            case "data": return url
            case "file": return url.standardizedFileURL
            default: return nil
            }
        }
        let path = d.removingPercentEncoding ?? d
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL }
        guard let doc = documentURL else { return nil }
        return URL(fileURLWithPath: path, relativeTo: doc.deletingLastPathComponent()).standardizedFileURL
    }

    /// Whether the app may read `file` on behalf of the document at `documentURL` (nil: untitled).
    /// Today every file the user can read: the editor has always shown absolute, `~/` and `..`
    /// pictures. **This is the function the sandbox milestone changes** (to the document's folder
    /// and the folders the user granted); the editor and the preview follow it together.
    public static func mayRead(_ file: URL, documentURL: URL?) -> Bool {
        file.isFileURL
    }

    /// When the file was last modified; nil when it cannot be read.
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `<name>.<ext>` in `directory`, or `<name> 2.<ext>`, `<name> 3.<ext>`... when taken.
    public static func uniqueURL(in directory: URL, name: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Writes `data` to a new file `<name>.<ext>` in `directory` (or `<name> 2.<ext>`...) and
    /// returns where. Never replaces a file, even one another paste is creating at the same
    /// moment: the name is only taken if the file did not exist when it was created.
    public static func writeNew(_ data: Data, in directory: URL, name: String, ext: String) throws -> URL {
        var n = 1
        while true {
            let candidate = directory.appendingPathComponent(n == 1 ? name : "\(name) \(n)").appendingPathExtension(ext)
            do {
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                n += 1
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                n += 1
            }
            if n > 10_000 { throw CocoaError(.fileWriteFileExists) }
        }
    }

    /// `file`'s path relative to the folder holding `document`, or the absolute path when
    /// `document` is nil (not saved yet).
    public static func path(of file: URL, relativeTo document: URL?) -> String {
        guard let document else { return file.path }
        let base = document.deletingLastPathComponent().standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        var i = 0
        while i < base.count, i < target.count, base[i] == target[i] { i += 1 }
        let ups = Array(repeating: "..", count: base.count - i)
        let rest = Array(target[i...])
        let parts = ups + rest
        return parts.isEmpty ? file.lastPathComponent : parts.joined(separator: "/")
    }
}
