import CoreServices
import Foundation

/// Lists what is in a root. Pure file-system reading, run on the library's queue.
public enum LibraryScanner {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]

    /// What the library does with an item: nil when it is left out (hidden, `node_modules`, over
    /// 4 MB, a symbolic link to a folder, which could loop).
    public static func entry(for url: URL, path: String) -> LibraryEntry? {
        guard !DocumentFileAccess.isSkipped(name: url.lastPathComponent),
              let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let modified = v.contentModificationDate ?? .distantPast
        if v.isSymbolicLink == true {
            // A link to a file stands for the file; one to a folder is not followed.
            guard let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)), target.isDirectory != true else { return nil }
            return fileEntry(url, path: path, modified: target.contentModificationDate ?? modified, size: target.fileSize ?? 0)
        }
        if v.isDirectory == true { return LibraryEntry(path: path, kind: .folder, modified: modified, size: 0) }
        return fileEntry(url, path: path, modified: modified, size: v.fileSize ?? 0)
    }

    private static func fileEntry(_ url: URL, path: String, modified: Date, size: Int) -> LibraryEntry? {
        guard size <= DocumentFileAccess.maximumNoteSize else { return nil }
        return LibraryEntry(path: path, kind: DocumentFileAccess.isNote(url) ? .note : .other, modified: modified, size: size)
    }

    /// Everything below `folder` (a path relative to `root`; empty for the root itself), folders
    /// included, depth first. The folder itself is not in the list.
    public static func scan(root: URL, folder: String = "") -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        let dir = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return out }
        for name in names.sorted() where !DocumentFileAccess.isSkipped(name: name) {
            let path = folder.isEmpty ? name : folder + "/" + name
            guard let e = entry(for: dir.appendingPathComponent(name), path: path) else { continue }
            out.append(e)
            if e.kind == .folder { out.append(contentsOf: scan(root: root, folder: path)) }
        }
        return out
    }
}

/// The file system's change notifications for some folders (FSEvents, file-level), delivered in
/// batches on a queue of the caller's.
final class FileEventStream {
    struct Event {
        var path: String
        /// Events were dropped or coalesced: the whole folder must be looked at again.
        var mustScan: Bool
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Event]) -> Void

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue, handler: @escaping ([Event]) -> Void) {
        guard !paths.isEmpty else { return nil }
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var events: [Event] = []
            for i in 0..<min(count, paths.count) {
                let f = eventFlags[i]
                let must = f & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
                events.append(Event(path: paths[i], mustScan: must))
            }
            me.handler(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    deinit { stop() }
}
