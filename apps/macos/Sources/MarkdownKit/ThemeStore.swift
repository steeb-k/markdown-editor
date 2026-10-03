import AppKit
import MarkdownCore

/// A core `Theme` turned into AppKit colors.
public struct ThemePalette {
    public let id: String
    public let isDark: Bool
    public let background, text, markup, heading, link, codeText, codeBackground, quote: NSColor
    public let selection, caret, focusDim, rule, tableBorder: NSColor
    public let posNoun, posVerb, posAdjective, posAdverb, posConjunction: NSColor
    public let authorAI, authorReference: NSColor
    /// The colours of highlighted code (the theme's `[syntax]` table).
    public let syntax: SyntaxColors

    /// The code highlighter's role colours.
    public struct SyntaxColors {
        public let comment, keyword, string, number, function, type, tag, variable: NSColor

        /// The colour of a run of code (`Invalid` is coloured like `Tag`).
        public func color(for role: CodeRole) -> NSColor {
            switch role {
            case .comment: return comment
            case .keyword: return keyword
            case .string: return string
            case .number: return number
            case .function: return function
            case .type: return type
            case .tag, .invalid: return tag
            case .variable: return variable
            }
        }
    }
}

public final class ThemeStore {
    public static let shared = ThemeStore()

    private let themes: [String: Theme]

    public init() {
        var t: [String: Theme] = [:]
        for theme in builtinThemes() { t[theme.id] = theme }
        themes = t
    }

    public static func color(_ c: ThemeColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    public func theme(id: String) -> Theme {
        themes[id] ?? themes["light"] ?? builtinThemes()[0]
    }

    /// The theme a choice means right now. `System` follows the given appearance.
    public func theme(for choice: ThemeChoice, appearance: NSAppearance?) -> Theme {
        switch choice {
        case .light: return theme(id: "light")
        case .dark: return theme(id: "dark")
        case .sepia: return theme(id: "sepia")
        case .system:
            let appearance = appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return theme(id: dark ? "dark" : "light")
        }
    }

    public func palette(_ theme: Theme) -> ThemePalette {
        let c = theme.colors
        let k = Self.color
        return ThemePalette(
            id: theme.id, isDark: theme.isDark,
            background: k(c.background), text: k(c.text), markup: k(c.markup), heading: k(c.heading),
            link: k(c.link), codeText: k(c.codeText), codeBackground: k(c.codeBackground), quote: k(c.quote),
            selection: k(c.selection), caret: k(c.caret), focusDim: k(c.focusDim), rule: k(c.rule),
            tableBorder: k(c.tableBorder),
            posNoun: k(c.posNoun), posVerb: k(c.posVerb), posAdjective: k(c.posAdjective), posAdverb: k(c.posAdverb),
            posConjunction: k(c.posConjunction), authorAI: k(c.authorAi), authorReference: k(c.authorReference),
            syntax: ThemePalette.SyntaxColors(
                comment: k(theme.syntax.comment), keyword: k(theme.syntax.keyword), string: k(theme.syntax.string),
                number: k(theme.syntax.number), function: k(theme.syntax.function), type: k(theme.syntax.type),
                tag: k(theme.syntax.tag), variable: k(theme.syntax.variable)))
    }

    /// The window appearance that makes native chrome match the theme (nil: follow the system).
    public static func windowAppearance(for choice: ThemeChoice) -> NSAppearance? {
        switch choice {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light, .sepia: return NSAppearance(named: .aqua)
        }
    }
}
