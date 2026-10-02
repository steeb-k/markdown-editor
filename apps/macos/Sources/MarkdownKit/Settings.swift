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
        ])
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

    public var autoHideChrome: Bool {
        get { defaults.bool(forKey: Key.autoHide) }
        set { defaults.set(newValue, forKey: Key.autoHide); changed() }
    }
}
