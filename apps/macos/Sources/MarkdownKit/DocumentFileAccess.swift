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
