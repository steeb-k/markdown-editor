import AppKit
import MarkdownCore

/// A template as the store found it on disk: a folder package `Name.mdtemplate` holding `template.toml` and, optionally,
/// `custom.css`. A package that does not parse is still listed (with its `error`), so it can be seen and removed.
public struct InstalledTemplate: Identifiable, Equatable {
    /// The package folder: what identifies the template, and where it is read from and saved to.
    public var url: URL
    public var name: String
    public var meta: TemplateMeta
    public var spec: TemplateSpec
    public var isBuiltIn: Bool
    /// The contents of `custom.css`, passed through untouched after the generated CSS (nil when there is none).
    public var customCSS: String?
    /// Why `template.toml` could not be read; such a template has an empty spec and is left out of resolution.
    public var error: String?
    /// The newest modification time of the package's two files, so a change made outside the app shows as a change.
    public var modified: Date

    public var id: URL { url }
    public var hasCustomCSS: Bool { customCSS != nil }
    public var isUsable: Bool { error == nil }
    public var template: Template { Template(meta: meta, spec: spec) }
}

public enum TemplateStoreError: LocalizedError, Equatable {
    case readOnly(String)
    case nothingToImport(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .readOnly(let name): return "\u{201C}\(name)\u{201D} is built in and cannot be changed. Duplicate it to make a copy of your own."
        case .nothingToImport(let name): return "\u{201C}\(name)\u{201D} holds no template styles to import."
        case .exportFailed(let why): return "The template could not be exported: \(why)"
        }
    }
}

/// The installed templates: the app's own (read-only, in the bundle) and the user's (in Application Support), as a small
/// observable model. SwiftUI observes it as an `ObservableObject`; AppKit listens for `didChangeNotification`. Main thread.
///
/// What is in a template package is the core's (`parseTemplate`, `templateToml`, `templateCss`); this class is the files
/// around that: listing, unique names, copying, importing and exporting, and which template a document gets.
public final class TemplateStore: ObservableObject {
    /// Posted (object: the store) when the list, or anything a template's CSS is made of, changed.
    public static let didChangeNotification = Notification.Name("MarkdownTemplatesDidChange")

    public static let packageExtension = "mdtemplate"
    public static let defaultName = "Default"

    /// The Templates window's way in, set by the window when it exists: Settings' "Manage Templates…" calls it.
    nonisolated(unsafe) public static var openManager: (() -> Void)?

    /// The app's store: the bundle's templates and the user's own.
    nonisolated(unsafe) public static var shared: TemplateStore = {
        let store = TemplateStore(builtInDirectory: defaultBuiltInDirectory, userDirectory: defaultUserDirectory)
        store.observesActivation()
        return store
    }()

    /// `Contents/Resources/Templates` of the app. A build run from the package (tests, `swift run`) has no bundle of
    /// its own, so the sources' copy is used there.
    static var defaultBuiltInDirectory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Templates", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        #if DEBUG || UI_SCRIPT
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Templates", isDirectory: true)
        #else
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Templates", isDirectory: true)
        #endif
    }

    /// `~/Library/Application Support/Markdown/Templates` (next to the history and the session record). A UI script and
    /// the tests get a folder of their own: nothing but the real app touches the user's.
    static var defaultUserDirectory: URL {
        #if DEBUG || UI_SCRIPT
        if let scripted = UIScriptRunner.templatesDirectory { return scripted }
        #endif
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Markdown-test-templates-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Markdown/Templates", isDirectory: true)
    }

    public let builtInDirectory: URL
    public let userDirectory: URL

    /// Every usable and unusable template: the built-in ones first, then the user's, each group in name order.
    @Published public private(set) var templates: [InstalledTemplate] = []

    private var signature = ""
    private var activation: NSObjectProtocol?

    public init(builtInDirectory: URL, userDirectory: URL) {
        self.builtInDirectory = builtInDirectory
        self.userDirectory = userDirectory
        reload()
    }

    deinit { if let activation { NotificationCenter.default.removeObserver(activation) } }

    /// Looks again whenever the app comes forward (a package may have been added, changed or removed in Finder).
    func observesActivation() {
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    // MARK: reading

    /// The built-in templates, then the user's.
    public var builtIn: [InstalledTemplate] { templates.filter(\.isBuiltIn) }
    public var yours: [InstalledTemplate] { templates.filter { !$0.isBuiltIn } }
    /// The templates a document can use, in name order (a template that does not parse is not one of them).
    public var usable: [InstalledTemplate] {
        templates.filter(\.isUsable).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func template(named name: String) -> InstalledTemplate? {
        let key = Self.key(name)
        return templates.first { $0.isUsable && Self.key($0.name) == key }
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Reads both folders again; posts a change when anything differs.
    public func reload() {
        var found = Self.read(builtInDirectory, builtIn: true) + Self.read(userDirectory, builtIn: false)
        // The built-in Default always exists: with the bundle's package missing, an empty spec is what it is.
        if !found.contains(where: { $0.isBuiltIn && Self.key($0.name) == Self.key(Self.defaultName) }) {
            let meta = TemplateMeta(name: Self.defaultName, author: "", version: "1", description: "The preview as it is.")
            found.insert(InstalledTemplate(url: builtInDirectory.appendingPathComponent("\(Self.defaultName).\(Self.packageExtension)", isDirectory: true),
                                           name: Self.defaultName, meta: meta, spec: Self.emptySpec, isBuiltIn: true, customCSS: nil, error: nil,
                                           modified: .distantPast), at: 0)
        }
        signature = currentSignature()
        guard found != templates else { return }
        templates = found
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// `reload()` when a package or a file in one has a new modification time (cheap enough for every activation).
    public func reloadIfChanged() {
        if currentSignature() != signature { reload() }
    }

    static var emptySpec: TemplateSpec { TemplateSpec(page: TemplatePage(), elements: []) }

    private func currentSignature() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        for dir in [builtInDirectory, userDirectory] {
            let packages = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for p in packages.sorted(by: { $0.path < $1.path }) where p.pathExtension == Self.packageExtension {
                parts.append(p.lastPathComponent)
                for file in ["template.toml", "custom.css"] {
                    let date = (try? p.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    parts.append("\(file)=\(date?.timeIntervalSinceReferenceDate ?? 0)")
                }
            }
        }
        return parts.joined(separator: "|")
    }

    private static func read(_ directory: URL, builtIn: Bool) -> [InstalledTemplate] {
        let fm = FileManager.default
        let packages = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return packages.filter { $0.pathExtension == packageExtension }.compactMap { readPackage($0, builtIn: builtIn) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func readPackage(_ url: URL, builtIn: Bool) -> InstalledTemplate? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let toml = url.appendingPathComponent("template.toml"), css = url.appendingPathComponent("custom.css")
        let folderName = url.deletingPathExtension().lastPathComponent
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let modified = max(date(toml), date(css))
        let customCSS = try? String(contentsOf: css, encoding: .utf8)
        var meta = TemplateMeta(name: folderName, author: "", version: "", description: "")
        var spec = emptySpec
        var problem: String?
        do {
            let text = try String(contentsOf: toml, encoding: .utf8)
            let parsed = try parseTemplate(toml: text)
            meta = parsed.meta
            spec = parsed.spec
            if meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meta.name = folderName }
        } catch let e as TemplateError {
            problem = Self.describe(e)
        } catch {
            problem = (error as NSError).localizedDescription
        }
        return InstalledTemplate(url: url, name: meta.name, meta: meta, spec: spec, isBuiltIn: builtIn, customCSS: customCSS, error: problem, modified: modified)
    }

    private static func describe(_ e: TemplateError) -> String {
        switch e {
        case .Syntax(let message): return message
        case .Value(let key, let message): return "\(key): \(message)"
        }
    }

    // MARK: CSS and resolution

    /// The stylesheet a document in `template` gets: the core's, then `custom.css` untouched (so it wins by the cascade).
    /// A template that did not parse gives the Default's.
    public func css(for template: InstalledTemplate, theme: Theme, typography: Typography) -> String {
        let generated = templateCss(spec: template.spec, theme: theme, typography: typography)
        guard template.isUsable, let custom = template.customCSS, !custom.isEmpty else { return generated }
        return generated + "\n" + custom
    }

    /// Which template a document gets: the one its front matter names (case-insensitively) when it is installed, else the
    /// app's default template, else the built-in Default. `note` says so when the front matter named one that is not there.
    public func resolve(frontMatterName: String?, defaultName: String? = nil) -> (template: InstalledTemplate, note: String?) {
        let wanted = frontMatterName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var note: String?
        if let wanted, !wanted.isEmpty {
            if let found = template(named: wanted) { return (found, nil) }
            let unreadable = templates.contains { !$0.isUsable && Self.key($0.name) == Self.key(wanted) }
            note = unreadable ? "\(wanted) (could not be read)" : "\(wanted) (not installed)"
        }
        let fallback = defaultName ?? Settings.shared.defaultTemplate
        return (template(named: fallback) ?? builtInDefault, note)
    }

    public var builtInDefault: InstalledTemplate {
        templates.first { $0.isBuiltIn && Self.key($0.name) == Self.key(Self.defaultName) } ?? templates[0]
    }

    // MARK: names

    /// `base` when no template has that name, else `base 2`, `base 3`, … (case-insensitively unique).
    public func uniqueName(_ base: String = "Untitled") -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Untitled" : trimmed
        let taken = Set(templates.map { Self.key($0.name) })
        if !taken.contains(Self.key(root)) { return root }
        var n = 2
        while taken.contains(Self.key("\(root) \(n)")) { n += 1 }
        return "\(root) \(n)"
    }

    /// The longest folder name a package gets before its extension, in UTF-16 units of its decomposed form (Foundation
    /// hands names to the file system decomposed, so `é` counts twice): a file name holds 255, and the extension, a " 99"
    /// to tell it apart and room to spare must fit too.
    static let maxFolderLength = 200

    /// The package folder for a name: the name with the characters a file name cannot hold replaced, cut to fit, and
    /// numbered when another package already has that folder (`current`, the template's own, does not count). Names are
    /// unique but folders are not by themselves: `A/B` and `A-B` make the same one, and a package's folder need not
    /// match the name in its `template.toml`, so writing to the folder a name gives could have replaced another template.
    func packageURL(for name: String, current: URL? = nil) -> URL {
        var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .filter { !$0.isNewline && !($0.unicodeScalars.first.map(CharacterSet.controlCharacters.contains) ?? false) }
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        while safe.decomposedStringWithCanonicalMapping.utf16.count > Self.maxFolderLength { safe.removeLast() }
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        if safe.isEmpty { safe = "Untitled" }
        let fm = FileManager.default
        let own = current?.standardizedFileURL.path.lowercased()
        func url(_ base: String) -> URL { userDirectory.appendingPathComponent("\(base).\(Self.packageExtension)", isDirectory: true) }
        // The volume may be case-insensitive: a folder that differs only in capitals is the same folder.
        func free(_ u: URL) -> Bool { u.standardizedFileURL.path.lowercased() == own || !fm.fileExists(atPath: u.path) }
        if free(url(safe)) { return url(safe) }
        var n = 2
        while !free(url("\(safe) \(n)")) { n += 1 }
        return url("\(safe) \(n)")
    }

    // MARK: writing (yours only)

    private func requireYours(_ t: InstalledTemplate) throws {
        if t.isBuiltIn { throw TemplateStoreError.readOnly(t.name) }
    }

    private func write(_ template: Template, to package: URL) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try templateToml(template: template).write(to: package.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
    }

    /// A new, empty template of your own (named `name`, made unique).
    @discardableResult
    public func create(_ name: String = "Untitled") throws -> InstalledTemplate {
        let unique = uniqueName(name)
        let meta = TemplateMeta(name: unique, author: "", version: "1", description: "")
        try write(Template(meta: meta, spec: Self.emptySpec), to: packageURL(for: unique))
        reload()
        return template(named: unique)!
    }

    /// A copy of `source` of your own, as `name` (made unique): styles and `custom.css` both.
    @discardableResult
    public func duplicate(_ source: InstalledTemplate, as name: String? = nil) throws -> InstalledTemplate {
        let unique = uniqueName(name ?? source.name + " Copy")
        let target = packageURL(for: unique)
        let fm = FileManager.default
        try fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: source.url, to: target)
        // The copy is a template of its own, under its own name.
        var meta = source.meta
        meta.name = unique
        if source.isUsable {
            try write(Template(meta: meta, spec: source.spec), to: target)
        }
        reload()
        return template(named: unique) ?? yours.first { $0.url.standardizedFileURL == target.standardizedFileURL }!
    }

    /// Gives one of yours another name (made unique among the others); the package folder follows.
    @discardableResult
    public func rename(_ t: InstalledTemplate, to newName: String) throws -> InstalledTemplate {
        try requireYours(t)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != t.name else { return t }
        // Only a change of capitals keeps the name it has; any other clash is made unique.
        let caseOnly = Self.key(trimmed) == Self.key(t.name)
        let name: String = caseOnly ? trimmed : uniqueName(trimmed)
        var meta = t.meta
        meta.name = name
        let target = packageURL(for: name, current: t.url)
        let fm = FileManager.default
        if target.standardizedFileURL != t.url.standardizedFileURL {
            // Through a temporary name: a rename of capitals only is the same file to a case-insensitive volume.
            let temp = userDirectory.appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: t.url, to: temp)
            do {
                try fm.moveItem(at: temp, to: target)
            } catch {
                // The temporary name is hidden and has no extension: left there, the template would vanish.
                try? fm.moveItem(at: temp, to: t.url)
                throw error
            }
        }
        if t.isUsable { try write(Template(meta: meta, spec: t.spec), to: target) }
        reload()
        return template(named: name) ?? yours.first { $0.url.standardizedFileURL == target.standardizedFileURL } ?? t
    }

    /// Writes `template.toml` of one of yours, atomically (`custom.css` is never touched).
    public func save(_ t: InstalledTemplate) throws {
        try requireYours(t)
        try write(Template(meta: t.meta, spec: t.spec), to: t.url)
        reload()
    }

    /// Moves one of yours to the Trash.
    public func delete(_ t: InstalledTemplate) throws {
        try requireYours(t)
        try FileManager.default.trashItem(at: t.url, resultingItemURL: nil)
        reload()
    }

    // MARK: import and export

    /// Reads a `.iatemplate` bundle (`Contents/Info.plist` for the name, `Contents/Resources/style.css` then `title.css`
    /// as the new package's `custom.css`), a plain `.css` file the same way, or an `.mdtemplate` package (copied).
    /// The styles of the new package are empty: what such a file says is CSS, which the structured styles do not parse.
    @discardableResult
    public func importTemplate(at url: URL) throws -> InstalledTemplate {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" { return try importZip(at: url) }
        if ext == Self.packageExtension {
            guard let source = Self.readPackage(url, builtIn: false) else { throw TemplateStoreError.nothingToImport(url.lastPathComponent) }
            return try duplicate(source, as: source.name)
        }
        var name = url.deletingPathExtension().lastPathComponent
        var css = ""
        if ext == "css" {
            css = try String(contentsOf: url, encoding: .utf8)
        } else {
            let contents = url.appendingPathComponent("Contents")
            if let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let bundleName = plist["CFBundleName"] as? String, !bundleName.trimmingCharacters(in: .whitespaces).isEmpty {
                name = bundleName
            }
            let parts = ["style.css", "title.css"].compactMap { try? String(contentsOf: contents.appendingPathComponent("Resources/\($0)"), encoding: .utf8) }
            css = parts.joined(separator: "\n")
            guard !parts.isEmpty else { throw TemplateStoreError.nothingToImport(url.lastPathComponent) }
        }
        let unique = uniqueName(name)
        let package = packageURL(for: unique)
        try write(Template(meta: TemplateMeta(name: unique, author: "", version: "1", description: ""), spec: Self.emptySpec), to: package)
        try css.write(to: package.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        reload()
        return template(named: unique)!
    }

    /// A zip archive holding a template, as Export writes one (`Name.mdtemplate.zip`) or as one is passed around: unpacked
    /// into a folder of its own, and the first package, bundle or stylesheet at its top imported as that would be.
    private func importZip(at url: URL) throws -> InstalledTemplate {
        let fm = FileManager.default
        let unpacked = fm.temporaryDirectory.appendingPathComponent("template-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: unpacked) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, unpacked.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let items = ((try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        let kinds = [Self.packageExtension, "iatemplate", "css"]
        guard process.terminationStatus == 0,
              let inner = kinds.lazy.compactMap({ kind in items.first { $0.pathExtension.lowercased() == kind } }).first
        else { throw TemplateStoreError.nothingToImport(url.lastPathComponent) }
        return try importTemplate(at: inner)
    }

    /// Copies the package to `destination` (a folder named `Name.mdtemplate`), or zips it there (`Name.mdtemplate.zip`).
    /// Whatever is at `destination` is replaced (the save panel has already asked).
    public func export(_ t: InstalledTemplate, to destination: URL, zipped: Bool) throws {
        let fm = FileManager.default
        // Replacing the package with itself would remove it first and then have nothing to copy.
        // (Through the parent: a path that does not exist yet keeps its symbolic links, `/var` for `/private/var`.)
        func canonical(_ u: URL) -> String {
            let u = u.standardizedFileURL
            return u.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(u.lastPathComponent).path.lowercased()
        }
        let packagePath = canonical(t.url)
        let destinationPath = canonical(destination)
        if destinationPath == packagePath || destinationPath.hasPrefix(packagePath + "/") {
            throw TemplateStoreError.exportFailed("a template cannot be exported into its own package.")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if !zipped {
            try fm.copyItem(at: t.url, to: destination)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", t.url.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TemplateStoreError.exportFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
