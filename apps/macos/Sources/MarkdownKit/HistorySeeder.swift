import Foundation
import MarkdownCore

/// Writes a made-up history for a file into the real store, so the History panel can be tried on something with a
/// past (`Markdown --seed-history <file> --seed-versions <json>`, run by `scripts/macos/seed-history-demo.sh`; the app
/// then exits). The key is derived by `HistoryKey` exactly as for an opened document, and the versions go through
/// `HistoryService`, so nothing here knows how the store lays itself out.
public enum HistorySeeder {
    /// One version in the JSON: when (local calendar days before today, at `hour`:`minute`), why, a message, and the
    /// lines of its text. A text of null is the file itself (the latest version, so that opening it shows no change).
    public struct Spec: Codable, Equatable {
        public var daysAgo: Int
        public var hour: Int
        public var minute: Int
        public var reason: String
        public var message: String?
        public var text: [String]?
    }

    struct Plan: Codable { var versions: [Spec] }

    public struct Outcome: Equatable {
        public var key: String
        /// What was recorded now, oldest first.
        public var recorded: [HistoryVersion]
        /// How many versions were left alone because the store already had their text.
        public var skipped: Int
    }

    public enum SeedError: Error, CustomStringConvertible {
        case unreadable(String)
        case badReason(String)
        case storeUnavailable

        public var description: String {
            switch self {
            case .unreadable(let what): return "cannot read \(what)"
            case .badReason(let r): return "unknown reason \"\(r)\""
            case .storeUnavailable: return "the history store cannot be opened"
            }
        }
    }

    public static func reason(_ name: String) -> HistoryReason? {
        switch name {
        case "pause": return .pause
        case "close": return .close
        case "save": return .save
        case "restore": return .restore
        case "draft": return .draft
        case "recovered": return .recovered
        default: return nil
        }
    }

    public static func specs(json: URL) throws -> [Spec] {
        guard let data = try? Data(contentsOf: json), let plan = try? JSONDecoder().decode(Plan.self, from: data) else {
            throw SeedError.unreadable(json.path)
        }
        return plan.versions
    }

    /// The time of a spec: its calendar day and clock time, never later than just before `now`, so the newest versions
    /// of "today" are not in the future when it is early in the day.
    static func time(of spec: Spec, index: Int, count: Int, now: Date, calendar: Calendar) -> Int64 {
        let day = calendar.date(byAdding: .day, value: -spec.daysAgo, to: calendar.startOfDay(for: now)) ?? now
        let at = calendar.date(bySettingHour: spec.hour, minute: spec.minute, second: 0, of: day) ?? day
        return Int64(min(at, now.addingTimeInterval(TimeInterval(-60 * (count - index)))).timeIntervalSince1970)
    }

    /// Records the versions of `specs` for `file`, oldest first. A version the store already holds for the key (same
    /// text, reason and message) is skipped, so a second run records nothing.
    public static func seed(file: URL, specs: [Spec], service: HistoryService, library: LibraryController?,
                            now: Date = Date(), calendar: Calendar = .current) throws -> Outcome {
        guard service.isAvailable else { throw SeedError.storeUnavailable }
        guard let data = try? Data(contentsOf: file), let fileText = String(data: data, encoding: .utf8) else {
            throw SeedError.unreadable(file.path)
        }
        let key = HistoryKey.key(for: file, library: library)
        // What the store holds already, as text, reason and message: a restore has the text of an older version, so the
        // text alone would not tell the two apart.
        struct Held: Hashable { var text: String; var reason: HistoryReason; var message: String? }
        var have = Set<Held>()
        for v in service.versionsNow(key: key) {
            if let t = service.textNow(key: key, id: v.id) { have.insert(Held(text: t, reason: v.reason, message: v.message)) }
        }
        var outcome = Outcome(key: key, recorded: [], skipped: 0)
        for (i, spec) in specs.enumerated() {
            guard let reason = reason(spec.reason) else { throw SeedError.badReason(spec.reason) }
            let text = spec.text.map { $0.joined(separator: "\n") + "\n" } ?? fileText
            let held = Held(text: text, reason: reason, message: spec.message)
            if have.contains(held) { outcome.skipped += 1; continue }
            let time = time(of: spec, index: i, count: specs.count, now: now, calendar: calendar)
            if let id = service.recordNow(key: key, text: text, reason: reason, message: spec.message, at: time) {
                have.insert(held)
                if let v = service.versionsNow(key: key).first(where: { $0.id == id }) { outcome.recorded.append(v) }
            }
        }
        return outcome
    }

    // MARK: the launch argument

    /// `--seed-history <file> --seed-versions <json>`: the two paths, or nil when the app was not asked to seed.
    nonisolated static func requested(arguments: [String] = ProcessInfo.processInfo.arguments) -> (file: URL, json: URL)? {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let file = value("--seed-history") else { return nil }
        let json = value("--seed-versions") ?? ""
        return (URL(fileURLWithPath: file), URL(fileURLWithPath: json))
    }

    /// Seeds the real store as a normal open would key it, prints what it did, and returns the exit status.
    @MainActor
    static func runFromLaunch(file: URL, json: URL) -> Int32 {
        let service = HistoryService(directory: DocumentFileAccess.historyDirectory)
        print("store: \(service.directory.path)")
        do {
            let library = Workspace.libraryController(for: Settings.shared)
            let outcome = try seed(file: file, specs: try specs(json: json), service: service, library: library)
            service.flush()
            print("key: \(outcome.key)")
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            for v in outcome.recorded {
                let when = f.string(from: Date(timeIntervalSince1970: TimeInterval(v.time)))
                print("recorded \(when)  \(HistoryModel.reasonText(v.reason).lowercased())  +\(v.added) -\(v.removed)" + (v.message.map { "  \"\($0)\"" } ?? ""))
            }
            print(outcome.recorded.isEmpty ? "nothing new: all \(outcome.skipped) versions are in the store already" : "recorded \(outcome.recorded.count), skipped \(outcome.skipped)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("seed-history: \(error)\n".utf8))
            return 1
        }
    }
}
