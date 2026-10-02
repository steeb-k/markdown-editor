import Foundation

public enum ThemeChoice: String, CaseIterable, Sendable {
    case system, light, dark, sepia

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        }
    }
}

public enum FontChoice: String, CaseIterable, Sendable {
    case iaMono, iaDuo, iaQuattro, systemMono, systemSerif, custom

    public var title: String {
        switch self {
        case .iaMono: return "Mono (bundled)"
        case .iaDuo: return "Duo (bundled)"
        case .iaQuattro: return "Quattro (bundled)"
        case .systemMono: return "System Mono"
        case .systemSerif: return "System Serif (New York)"
        case .custom: return "Custom…"
        }
    }
}

/// How much text focus mode keeps at full strength (the shell's name for the core's `FocusScope`).
public enum FocusScopeChoice: String, CaseIterable, Sendable {
    case sentence, paragraph

    public var title: String {
        switch self {
        case .sentence: return "Sentence"
        case .paragraph: return "Paragraph"
        }
    }
}

/// The five classes of words syntax highlighting can colour.
public enum SyntaxClass: String, CaseIterable, Sendable {
    case noun, verb, adjective, adverb, conjunction

    public var title: String {
        switch self {
        case .noun: return "Nouns"
        case .verb: return "Verbs"
        case .adjective: return "Adjectives"
        case .adverb: return "Adverbs"
        case .conjunction: return "Conjunctions"
        }
    }
}

/// Every preference, in one place, stored in `UserDefaults`. The core holds no preferences.
/// Changes post `Settings.didChangeNotification` so every open document applies them live.
public final class Settings: NSObject {
    public static let didChangeNotification = Notification.Name("MarkdownSettingsDidChange")
    public static let shared: Settings = {
        #if DEBUG || UI_SCRIPT
        // A UI script runs on its own defaults, never the user's.
        if let d = UIScriptRunner.scriptDefaults() { return Settings(defaults: d) }
        #endif
        return Settings(defaults: .standard)
    }()

    public static let fontSizeRange: ClosedRange<Double> = 9...40
    public static let lineWidthRange: ClosedRange<Int> = 30...160

    public let defaults: UserDefaults

    private enum Key {
        static let theme = "theme"
        static let font = "fontChoice"
        static let customFamily = "customFontFamily"
        static let fontSize = "fontSize"
        static let lineWidth = "lineWidth"
        static let spellCheck = "spellCheck"
        static let showToolbar = "showFormattingToolbar"
        static let autoHide = "autoHideChrome"
        static let defaultViewMode = "defaultViewMode"
        static let focusMode = "focusMode"
        static let focusScope = "focusScope"
        static let syntaxHighlight = "syntaxHighlight"
        static let authorshipDisplay = "authorshipDisplay"
        static let authorName = "authorName"
        static func syntaxClass(_ c: SyntaxClass) -> String { "syntax." + c.rawValue }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        defaults.register(defaults: [
            Key.theme: ThemeChoice.system.rawValue,
            Key.font: FontChoice.iaQuattro.rawValue,
            Key.customFamily: "",
            Key.fontSize: 17.0,
            Key.lineWidth: 72,
            Key.spellCheck: true,
            Key.showToolbar: true,
            Key.autoHide: true,
            Key.defaultViewMode: ViewMode.source.rawValue,
            Key.focusMode: false,
            Key.focusScope: FocusScopeChoice.sentence.rawValue,
            Key.syntaxHighlight: false,
            Key.authorshipDisplay: true,
            Key.authorName: "",
        ].merging(Dictionary(uniqueKeysWithValues: SyntaxClass.allCases.map { (Key.syntaxClass($0), true as Any) })) { a, _ in a })
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public var theme: ThemeChoice {
        get { ThemeChoice(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.theme); changed() }
    }

    public var fontChoice: FontChoice {
        get { FontChoice(rawValue: defaults.string(forKey: Key.font) ?? "") ?? .iaQuattro }
        set { defaults.set(newValue.rawValue, forKey: Key.font); changed() }
    }

    public var customFontFamily: String {
        get { defaults.string(forKey: Key.customFamily) ?? "" }
        set { defaults.set(newValue, forKey: Key.customFamily); changed() }
    }

    public var fontSize: Double {
        get {
            let v = defaults.double(forKey: Key.fontSize)
            return min(max(v, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        }
        set {
            let v = min(max(newValue, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            defaults.set(v, forKey: Key.fontSize); changed()
        }
    }

    /// Maximum measure of the text column, in characters of the current font.
    public var lineWidth: Int {
        get { min(max(defaults.integer(forKey: Key.lineWidth), Self.lineWidthRange.lowerBound), Self.lineWidthRange.upperBound) }
        set {
            let v = min(max(newValue, Self.lineWidthRange.lowerBound), Self.lineWidthRange.upperBound)
            defaults.set(v, forKey: Key.lineWidth); changed()
        }
    }

    public var spellCheck: Bool {
        get { defaults.bool(forKey: Key.spellCheck) }
        set { defaults.set(newValue, forKey: Key.spellCheck); changed() }
    }

    public var showFormattingToolbar: Bool {
        get { defaults.bool(forKey: Key.showToolbar) }
        set { defaults.set(newValue, forKey: Key.showToolbar); changed() }
    }

    /// The mode new windows start in. Styled source unless the user picks Live.
    public var defaultViewMode: ViewMode {
        get { ViewMode(rawValue: defaults.string(forKey: Key.defaultViewMode) ?? "") ?? .source }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultViewMode); changed() }
    }

    public var autoHideChrome: Bool {
        get { defaults.bool(forKey: Key.autoHide) }
        set { defaults.set(newValue, forKey: Key.autoHide); changed() }
    }

    /// Whether new windows start in focus mode. (Each window toggles its own.)
    public var focusMode: Bool {
        get { defaults.bool(forKey: Key.focusMode) }
        set { defaults.set(newValue, forKey: Key.focusMode); changed() }
    }

    /// Sentence or paragraph: how much focus mode keeps lit, in every window.
    public var focusScope: FocusScopeChoice {
        get { FocusScopeChoice(rawValue: defaults.string(forKey: Key.focusScope) ?? "") ?? .sentence }
        set { defaults.set(newValue.rawValue, forKey: Key.focusScope); changed() }
    }

    /// Whether new windows start with syntax (parts of speech) highlighting on.
    public var syntaxHighlight: Bool {
        get { defaults.bool(forKey: Key.syntaxHighlight) }
        set { defaults.set(newValue, forKey: Key.syntaxHighlight); changed() }
    }

    /// Whether new windows colour borrowed text (AI, Reference). Each window toggles its own;
    /// the colouring never touches the text or the file.
    public var authorshipDisplay: Bool {
        get { defaults.bool(forKey: Key.authorshipDisplay) }
        set { defaults.set(newValue, forKey: Key.authorshipDisplay); changed() }
    }

    /// The name written for the user's own text in an annotation block (`@Name: ...`). Empty
    /// means the macOS full user name.
    public var authorNameSetting: String {
        get { defaults.string(forKey: Key.authorName) ?? "" }
        set { defaults.set(newValue, forKey: Key.authorName); changed() }
    }

    /// The name that is in effect: the setting, else the full user name, else "Me".
    public var authorName: String {
        let chosen = authorNameSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return chosen }
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? "Me" : full
    }

    /// The classes of words that are coloured, in every window.
    public func syntaxClass(_ c: SyntaxClass) -> Bool { defaults.bool(forKey: Key.syntaxClass(c)) }

    public func setSyntaxClass(_ c: SyntaxClass, _ on: Bool) {
        defaults.set(on, forKey: Key.syntaxClass(c))
        changed()
    }

    public var syntaxClasses: Set<SyntaxClass> { Set(SyntaxClass.allCases.filter { syntaxClass($0) }) }
}
