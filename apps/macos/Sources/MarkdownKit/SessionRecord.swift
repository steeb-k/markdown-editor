import AppKit
import os

/// What the app remembers of its windows between launches: one JSON file (`DocumentFileAccess.sessionRecordURL`) listing
/// every document window in z-order with everything needed to put it back. The app writes it itself, a moment after
/// anything in it changes and once more on quit, and reads it at launch (see `SessionRestorer`); NSDocument's own
/// restoration depends on a system setting ("Close windows when quitting") and cannot bring back the sidebar, so it is
/// not what the windows come back from.
///
/// Every field is optional on reading: a record written by an older or a newer version still restores what it can, keys
/// that are not known are ignored, and a file that is not a record at all restores nothing.
public struct SessionRecord: Codable, Equatable {
    public static let currentVersion = 1
    /// The longest untitled text the record keeps (a document bigger than this comes back empty rather than the record
    /// growing without limit).
    public static let untitledTextLimit = 2_000_000

    public var version: Int?
    /// The windows, front-most first.
    public var windows: [Window]
    /// The index in `windows` of the key window.
    public var key: Int?

    public init(windows: [Window] = [], key: Int? = nil) {
        version = Self.currentVersion
        self.windows = windows
        self.key = key
    }

    public struct Window: Codable, Equatable {
        /// The file, or nil for an untitled document (whose text is `untitledText`).
        public var file: DocumentFileAccess.FileRef?
        public var untitledText: String?
        /// The window's frame when it is not full screen (x, y, width, height), and the screen it was on.
        public var frame: [Double]?
        public var screen: String?
        public var fullScreen: Bool?
        public var layout: String?
        public var focus: Bool?
        public var syntax: Bool?
        public var authorship: Bool?
        public var notes: Notes?
        public var column: Column?
        /// The selection (location, length), and the character at the top of the editor with how far into its line.
        public var caret: [Int]?
        public var scrollCharacter: Int?
        public var scrollInto: Double?

        public init() {}
    }

    /// A window's workspace, when it is in notes mode. The roots are the library's and live in the settings.
    public struct Notes: Codable, Equatable {
        public var selection: [String]?
        public var expanded: [String]?
        public var tags: [String]?
        public var search: String?
        public var sort: String?
        public var backlinks: Bool?
        public var tagsCollapsed: Bool?
        public var sidebarWidth: Double?
        public var scroll: Double?

        public init() {}
    }

    public struct Column: Codable, Equatable {
        public var shown: Bool?
        public var pane: String?
        public var width: Double?

        public init() {}
    }

    // MARK: reading and writing

    /// The record in `data`, or nil when it is not one (not JSON, another shape, a version from the future).
    public static func decode(_ data: Data) -> SessionRecord? {
        guard let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return nil }
        if let v = record.version, v > currentVersion { return nil }
        return record
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func read(from url: URL = DocumentFileAccess.sessionRecordURL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Atomically: a temporary file in the same folder, then a rename.
    public func write(to url: URL = DocumentFileAccess.sessionRecordURL) throws {
        try DocumentFileAccess.createDirectory(url.deletingLastPathComponent())
        try DocumentFileAccess.write(try encoded(), to: url)
    }

    /// The log's own: a skipped file is noted here and nowhere on screen.
    static let log = Logger(subsystem: "io.github.steeb-k.Markdown", category: "session")
}

// MARK: - writing

/// Writes the record: coalesced, a moment after anything it holds changes (`noteChange`), and at once on quit (`writeNow`).
public final class SessionRecorder {
    /// The app's recorder; nil when nothing writes (a UI script or a test that did not ask).
    nonisolated(unsafe) public static var current: SessionRecorder?
    /// How long after a change the record is written (a burst of changes shares one write).
    public static let delay: TimeInterval = 0.5

    public let url: URL
    public var interval: TimeInterval
    /// The windows to record, front-most first (the app's own; tests give theirs).
    public var windows: () -> [EditorWindowController] = { SessionRecorder.documentWindows() }
    /// Told after each write (tests).
    public var onWrite: ((SessionRecord) -> Void)?
    public private(set) var writes = 0
    /// No writes while windows are being put back (a half-restored record would replace the whole one) and none after the
    /// final one (the windows that close as the app ends are not a change).
    public var suspended = false
    public private(set) var finished = false
    private var timer: Timer?
    private var files: [String: DocumentFileAccess.FileRef] = [:]

    public init(url: URL = DocumentFileAccess.sessionRecordURL, interval: TimeInterval = SessionRecorder.delay) {
        self.url = url
        self.interval = interval
    }

    /// Something the record holds changed: it is written `interval` after the first change of a burst.
    public func noteChange() {
        guard !finished, !suspended, timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Writes the record now. `final`: the app is quitting, nothing is written after this.
    @discardableResult
    public func writeNow(final: Bool = false) -> SessionRecord? {
        timer?.invalidate()
        timer = nil
        guard !finished, !suspended else { return nil }
        if final { finished = true }
        let record = capture()
        do {
            try record.write(to: url)
            writes += 1
            onWrite?(record)
        } catch {
            SessionRecord.log.error("cannot write the session record: \(error.localizedDescription, privacy: .public)")
        }
        return record
    }

    /// A quit that did not happen: the record is written again as things change.
    public func resume() {
        finished = false
        noteChange()
    }

    /// The windows as they are.
    public func capture() -> SessionRecord {
        let all = windows()
        var states: [SessionRecord.Window] = []
        var keyIndex: Int?
        let key = NSApp.keyWindow?.windowController
        for wc in all {
            guard var state = wc.sessionState() else { continue }
            // A bookmark is made once per file.
            if let url = wc.fileURL {
                if let known = files[url.path] { state.file = known } else { files[url.path] = state.file }
            }
            if wc === key { keyIndex = states.count }
            states.append(state)
        }
        return SessionRecord(windows: states, key: keyIndex ?? (states.isEmpty ? nil : 0))
    }

    /// The document windows, front-most first: the ones on screen in order, then any other.
    public static func documentWindows() -> [EditorWindowController] {
        var out: [EditorWindowController] = []
        for w in NSApp.orderedWindows + NSApp.windows {
            if let c = w.windowController as? EditorWindowController, !out.contains(where: { $0 === c }) { out.append(c) }
        }
        return out
    }
}
