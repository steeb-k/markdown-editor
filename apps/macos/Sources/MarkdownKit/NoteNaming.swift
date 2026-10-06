import Foundation
import MarkdownCore

/// The daily note's file name: a format such as `YYYY-MM-DD` filled in from a date.
public enum DailyNote {
    public static let defaultFormat = "YYYY-MM-DD"

    /// Tokens, longest first: `YYYY` `YY` (year), `MMMM` `MMM` `MM` `M` (month), `DD` `D` (day),
    /// `dddd` `ddd` (weekday), `HH` `H` `mm` `ss` (time). Text in `[square brackets]` is kept as
    /// written; any other character stands for itself.
    private static let tokens: [(String, String)] = [
        ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
        ("DD", "dd"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("HH", "HH"), ("H", "H"), ("mm", "mm"), ("ss", "ss"),
    ]

    /// The date written out by `format`, as it stands.
    public static func render(_ date: Date, format: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        var out = ""
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            if chars[i] == "[", let close = chars[(i + 1)...].firstIndex(of: "]") {
                out += String(chars[(i + 1)..<close])
                i = close + 1
                continue
            }
            let rest = String(chars[i...])
            if let (token, pattern) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                f.dateFormat = pattern
                out += f.string(from: date)
                i += token.count
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// The file name (without extension) for `date`: no folder separators, no colon (Finder shows it as a
    /// slash), no blanks around; `YYYY-MM-DD` when the format makes nothing.
    public static func name(for date: Date, format: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let out = render(date, format: format, calendar: calendar, locale: locale)
        let clean = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? name(for: date, format: defaultFormat, calendar: calendar, locale: locale) : clean
    }
}

/// Templates: files in the templates folder with `{{date}}`, `{{time}}`, `{{title}}`, `{{today}}` and
/// `{{cursor}}` in them; the core expands them.
public enum NoteTemplates {
    /// The values the core fills in: `date` as `YYYY-MM-DD`, `time` as `HH:mm`, `title` the new note's
    /// name, `today` the date in the daily note's format.
    public static func variables(title: String, date: Date, dailyFormat: String,
                                 calendar: Calendar = .current, locale: Locale = .current) -> [String: String] {
        [
            "date": DailyNote.render(date, format: "YYYY-MM-DD", calendar: calendar, locale: locale),
            "time": DailyNote.render(date, format: "HH:mm", calendar: calendar, locale: locale),
            "title": title,
            "today": DailyNote.name(for: date, format: dailyFormat, calendar: calendar, locale: locale),
        ]
    }

    public static func expand(_ text: String, title: String, date: Date, dailyFormat: String,
                              calendar: Calendar = .current, locale: Locale = .current) -> NoteTemplate {
        expandTemplate(text: text, vars: variables(title: title, date: date, dailyFormat: dailyFormat, calendar: calendar, locale: locale))
    }

    /// The templates in a folder (note files, by name).
    public static func list(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !DocumentFileAccess.isSkipped(name: $0) }
            .map { folder.appendingPathComponent($0) }
            .filter { DocumentFileAccess.isNote($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

public enum NoteNaming {
    /// What the user typed as a new name, as a name a file can have: nil for an empty one, one
    /// that starts with a dot (the library does not show hidden files) or is only dots.
    public static func fileName(from typed: String) -> String? {
        let clean = typed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("."), !clean.contains("\0") else { return nil }
        return clean
    }

    /// Where `old` goes when it is renamed to `typed`. A note keeps its extension unless the user
    /// typed another note extension (`Idea.txt`).
    public static func renamed(_ old: URL, to typed: String) -> URL? {
        guard let name = fileName(from: typed) else { return nil }
        let dir = old.deletingLastPathComponent()
        if DocumentFileAccess.isDirectory(old) { return dir.appendingPathComponent(name, isDirectory: true) }
        let typedExt = (name as NSString).pathExtension.lowercased()
        if DocumentFileAccess.noteExtensions.contains(typedExt) { return dir.appendingPathComponent(name) }
        return dir.appendingPathComponent(name).appendingPathExtension(old.pathExtension)
    }

    /// The question a rename asks when notes link to the one being renamed: "Update 3 links in 2 notes?".
    public static func linkUpdateQuestion(_ edits: [LibraryEdit]) -> String {
        let notes = Set(edits.map(\.note)).count
        return "Update \(edits.count) link\(edits.count == 1 ? "" : "s") in \(notes) note\(notes == 1 ? "" : "s")?"
    }
}
