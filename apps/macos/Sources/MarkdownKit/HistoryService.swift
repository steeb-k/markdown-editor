import Foundation
import CryptoKit
import MarkdownCore

extension Notification.Name {
    /// A snapshot was recorded (on the main thread); `object` is the `HistoryService`, `userInfo["key"]` the document key.
    static let historyDidRecord = Notification.Name("io.github.steeb-k.Markdown.historyDidRecord")
    /// A document's file was changed by another app and re-read; `object` is the `MarkdownDocument`.
    static let documentChangedOnDisk = Notification.Name("io.github.steeb-k.Markdown.documentChangedOnDisk")
}

/// The app's side of the core's snapshot store: every call is made on a serial background queue, so typing never
/// waits for the disk, and answers come back on the main thread. One per process (`current`); nil means history is
/// off (unit tests that do not ask for it, and a store folder that could not be made).
public final class HistoryService: @unchecked Sendable {
    /// The service documents record into. Set at launch (`AppDelegate`), by the UI harness to a folder of its own, and
    /// by tests; never created on demand, so nothing but the app writes to the real folder.
    nonisolated(unsafe) public static var current: HistoryService?

    public let directory: URL
    private let store: HistoryStore?
    private let queue = DispatchQueue(label: "io.github.steeb-k.Markdown.history", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
        store = try? HistoryStore.open(dir: directory.path)
    }

    public var isAvailable: Bool { store != nil }

    /// Records `text` for `key` unless it is what the latest snapshot holds. `completion` (main thread) gets the new
    /// version's id, nil when nothing was recorded.
    public func record(key: String, text: String, reason: HistoryReason, message: String? = nil,
                       at time: Int64? = nil, completion: ((UInt64?) -> Void)? = nil) {
        queue.async { [self] in
            let id = time.map { store?.recordAt(key: key, text: text, reason: reason, message: message, now: $0) }
                ?? store?.record(key: key, text: text, reason: reason, message: message)
            DispatchQueue.main.async { [self] in
                if id != nil { NotificationCenter.default.post(name: .historyDidRecord, object: self, userInfo: ["key": key]) }
                completion?(id)
            }
        }
    }

    public func versions(key: String, completion: @escaping ([HistoryVersion]) -> Void) {
        queue.async { [self] in
            let v = store?.versions(key: key) ?? []
            DispatchQueue.main.async { completion(v) }
        }
    }

    public func text(key: String, id: UInt64, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            let t = store?.text(key: key, id: id)
            DispatchQueue.main.async { completion(t) }
        }
    }

    /// The line diff from version `id` to `current`, worked out off the main thread.
    public func diff(key: String, id: UInt64, current: String, completion: @escaping ([HistoryHunk]?) -> Void) {
        queue.async { [self] in
            let d = store?.diff(key: key, id: id, current: current)
            DispatchQueue.main.async { completion(d) }
        }
    }

    /// The history of `old` is `new`'s from now on (a rename or a move).
    public func rekey(_ old: String, to new: String) {
        guard old != new else { return }
        queue.async { [self] in _ = store?.rekey(old: old, new: new) }
    }

    /// A note, or a folder with the notes in it, moved in the library: the histories of what moved follow it.
    public func rekeyMoved(from old: NoteRef, to new: NoteRef) {
        queue.async { [self] in
            guard let store else { return }
            let (oldKey, newKey) = (HistoryKey.key(for: old), HistoryKey.key(for: new))
            _ = store.rekey(old: oldKey, new: newKey)
            // A folder: every note below it.
            for key in store.keys() where key.hasPrefix(oldKey + "/") {
                _ = store.rekey(old: key, new: newKey + key.dropFirst(oldKey.count))
            }
        }
    }

    public func forget(key: String) {
        queue.async { [self] in store?.forget(key: key) }
    }

    /// Returns once everything asked of the service so far has been done (quitting, and tests).
    public func flush() { queue.sync {} }

    /// The versions of `key` as of now, asked and waited for (tests and the UI harness; the app never blocks on the store).
    public func versionsNow(key: String) -> [HistoryVersion] { queue.sync { store?.versions(key: key) ?? [] } }

    /// The text of a version, asked and waited for (tests and the UI harness).
    public func textNow(key: String, id: UInt64) -> String? { queue.sync { store?.text(key: key, id: id) } }
}

/// Which history a document has: the note it is in the library (the same note under a new name keeps it through
/// `rekey`), or, for a file outside every root, its place. Plain strings: the folder the store makes of them is the
/// core's business.
public enum HistoryKey {
    public static func key(for note: NoteRef) -> String { "note:\(note.root)/\(note.path)" }

    /// A file outside the library: a hash of its canonical path. (The file's bookmark would follow it past a rename
    /// outside the app, but two bookmarks of one file are not the same bytes, and the file's identity changes with
    /// every atomic write, so there is nothing stable to hash.)
    public static func key(forFile url: URL) -> String {
        let path = DocumentFileAccess.canonical(url).path
        let digest = SHA256.hash(data: Data(path.utf8))
        return "file:" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func key(for url: URL, library: LibraryController?) -> String {
        if let ref = library?.ref(for: url) { return key(for: ref) }
        return key(forFile: url)
    }
}
