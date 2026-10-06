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

    // MARK: pictures: one rule for the preview, PDF and print

    /// The schemes a picture is fetched from over the network (by the preview's web view itself),
    /// subject to the App Transport Security settings in Info.plist.
    public static let remotePictureSchemes: Set<String> = ["http", "https"]

    /// Where the picture a Markdown document names (`![](destination)`, or an `<img src>`) is:
    /// an `http(s)` URL, a `data:` URL, or a file (a `file:` URL, an absolute path, `~/`, or a path
    /// relative to the document's folder, `..` included). Nil when it cannot be resolved (a
    /// relative path in a document never saved, another scheme). Percent-escapes in a path are
    /// decoded once, so the destination as written and the same destination as an escaped `src`
    /// attribute give the same file.
    ///
    /// The preview, PDF and print (`PreviewSchemeHandler`) ask here and then `mayRead`.
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

    // MARK: notes and folders: the library's files

    /// The extensions of the files the library indexes as notes.
    public static let noteExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]

    /// Files bigger than this are left out of the library altogether (the editor still opens them).
    public static let maximumNoteSize = 4 * 1024 * 1024

    public static func isNote(_ url: URL) -> Bool { noteExtensions.contains(url.pathExtension.lowercased()) }

    /// Whether the library skips an item of this name: hidden items and `node_modules`.
    public static func isSkipped(name: String) -> Bool { name.hasPrefix(".") || name == "node_modules" }

    /// Where the library lives unless the user chooses another folder.
    public static var defaultLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Markdown Notes", isDirectory: true)
    }

    /// The same location with symbolic links resolved (`/var` and `/private/var`), which is how
    /// the file system reports paths in events and how the library compares them.
    ///
    /// A place that does not exist (a file just deleted, a name about to be made) is resolved through its
    /// nearest folder that does, so it is spelled as the same place is when it exists.
    public static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while existing.pathComponents.count > 1, !FileManager.default.fileExists(atPath: existing.path) {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath().standardizedFileURL
        for name in tail { out.appendPathComponent(name) }
        return out
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    public static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: the history store

    /// Where the app keeps the snapshot history (`~/Library/Application Support/Markdown/history`; inside the container
    /// in a sandboxed build). The core owns what is inside; the folder is made when the store opens it.
    public static var historyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Markdown/history", isDirectory: true)
    }

    // MARK: the session record

    /// Where the app's record of its open windows is (`session.json` next to `history`). A UI script and the tests
    /// point it somewhere of their own; nothing but the real app ever uses the user's.
    nonisolated(unsafe) public static var sessionRecordOverride: URL?

    public static var sessionRecordURL: URL {
        sessionRecordOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Markdown/session.json")
    }

    /// A file as the record remembers it: a bookmark (so a file that was moved or renamed is still found), beside
    /// the path it had.
    public struct FileRef: Codable, Equatable {
        public var path: String
        public var bookmark: Data?
        public init(path: String, bookmark: Data?) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    public static func makeFileRef(_ file: URL) -> FileRef {
        let data = (try? file.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        return FileRef(path: file.path, bookmark: data)
    }

    /// The file a reference stands for, or nil when it is not there any more. Never mounts a volume or asks anything.
    public static func resolve(_ ref: FileRef) -> URL? {
        var url = URL(fileURLWithPath: ref.path)
        if let data = ref.bookmark {
            var stale = false
            if let resolved = (try? URL(resolvingBookmarkData: data, options: resolveOptions.union(.withSecurityScope), relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)) {
                url = resolved
            }
        }
        // A bookmark follows a file into the Trash: a file that was thrown away is gone.
        if url.path.contains("/.Trash/") { return nil }
        _ = url.startAccessingSecurityScopedResource()
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue ? url : nil
    }

    // MARK: folders the user grants

    /// A folder the user chose, as it is remembered: a security-scoped bookmark (which an
    /// unsandboxed build creates and resolves too, so the App Store build needs nothing new)
    /// beside the path it pointed at when it was made.
    public struct Grant: Codable, Equatable {
        public var id: String
        public var path: String
        public var bookmark: Data?
        public init(id: String, path: String, bookmark: Data?) {
            self.id = id
            self.path = path
            self.bookmark = bookmark
        }
    }

    public static func makeGrant(id: String, folder: URL) -> Grant {
        let data = (try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        return Grant(id: id, path: folder.path, bookmark: data)
    }

    /// The folder a grant stands for and access to it (kept until the app ends). A moved folder
    /// is found through its bookmark; without one, by its path.
    ///
    /// Never mounts a volume or asks anything: this runs on the main thread when a window turns notes mode
    /// on, and a folder on a drive that is not connected (or a server that is not reachable) would otherwise
    /// hold it while the system tries; such a folder is simply not there until the drive is.
    public static func open(_ grant: Grant) -> URL? {
        var url = URL(fileURLWithPath: grant.path, isDirectory: true)
        if let data = grant.bookmark {
            var stale = false
            if let resolved = (try? URL(resolvingBookmarkData: data, options: resolveOptions.union(.withSecurityScope), relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)) {
                url = resolved
            }
        }
        _ = url.startAccessingSecurityScopedResource()
        return isDirectory(url) ? url : nil
    }

    /// How a grant's bookmark is resolved: without mounting anything and without any panel.
    static let resolveOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]

    /// The folder, made when it is not there.
    public static func ensureFolder(_ url: URL) throws {
        if !isDirectory(url) { try createDirectory(url) }
    }

    // MARK: coordinated reads and writes of the library's files

    /// Reads `url` as a file coordinator would let another editor have it (a note someone else is
    /// writing is waited for).
    public static func readCoordinated(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in
            result = Result { try read(u) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Told of each coordinated write, on the thread that makes it (tests).
    nonisolated(unsafe) public static var coordinatedWriteObserver: ((URL) -> Void)?

    /// Writes `data` over `url` through a file coordinator, so a document that has the file open
    /// (a file presenter) is told and reads it again.
    public static func writeCoordinated(_ data: Data, to url: URL) throws {
        coordinatedWriteObserver?(url)
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { u in
            result = Result { try write(data, to: u) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Moves a file or folder (a rename is a move in the same folder). Coordinated, which is how
    /// an open document learns its file has a new name.
    public static func move(_ from: URL, to: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving,
                                                         writingItemAt: to, options: .forReplacing, error: &coordinationError) { a, b in
            result = Result { try FileManager.default.moveItem(at: a, to: b) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    public static func copy(_ from: URL, to: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: from, options: [], writingItemAt: to, options: .forReplacing,
                                                         error: &coordinationError) { a, b in
            result = Result { try FileManager.default.copyItem(at: a, to: b) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Told what was moved to the Trash and where it went (tests and the UI harness).
    nonisolated(unsafe) public static var trashObserver: ((URL, URL?) -> Void)?

    /// To the Trash. Never unlinks: what the user trashes can be put back from there.
    @discardableResult
    public static func trash(_ url: URL) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        trashObserver?(url, trashed as URL?)
        return trashed as URL?
    }

    /// An unused name in `directory`: `base`, `base 2`, `base 3`... with the extension `ext` (empty
    /// for a folder).
    public static func uniqueName(in directory: URL, base: String, ext: String) -> URL {
        var n = 1
        while true {
            let stem = n == 1 ? base : "\(base) \(n)"
            let candidate = ext.isEmpty ? directory.appendingPathComponent(stem, isDirectory: true)
                : directory.appendingPathComponent(stem).appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
