import AppKit
import MarkdownCore

/// Everything the styler and the text view need to know about how text looks right now:
/// palette, fonts, size and column geometry. Rebuilt on theme, font or appearance changes.
public struct EditorAppearance {
    public let choice: ThemeChoice
    public let theme: Theme
    public let palette: ThemePalette
    public let fonts: FontSet
    /// Total line height as a multiple of the font size.
    public let lineHeight: CGFloat
    /// The editor column's width in characters: the document's own `line_width:` when it has one, else the setting.
    public let maxCharacters: Int
    /// The setting's width alone, which the preview's column keeps whatever a document says (templates govern it).
    public let settingsCharacters: Int

    /// Space above the first line and below the last, inside the scroll view's content insets
    /// (which already keep clear of the title bar and the toolbar).
    public static let topInset: CGFloat = 52
    public static let minimumSideMargin: CGFloat = 28

    public init(settings: Settings, appearance: NSAppearance?, documentLineWidth: Int? = nil, store: ThemeStore = .shared) {
        choice = settings.theme
        theme = store.theme(for: settings.theme, appearance: appearance)
        palette = store.palette(theme)
        fonts = FontStore.fonts(choice: settings.fontChoice, customFamily: settings.customFontFamily,
                                size: CGFloat(settings.fontSize))
        lineHeight = 1.5
        settingsCharacters = settings.lineWidth
        maxCharacters = documentLineWidth ?? settings.lineWidth
    }

    /// Width of the text column: `maxCharacters` of the current font ("0" is the yardstick).
    public var measure: CGFloat {
        let w = ("0" as NSString).size(withAttributes: [.font: fonts.body]).width
        return (w * CGFloat(maxCharacters)).rounded()
    }

    public func lineSpacing(for font: NSFont, multiple: CGFloat? = nil) -> CGFloat {
        let natural = font.ascender - font.descender + font.leading
        return max(0, (font.pointSize * (multiple ?? lineHeight) - natural).rounded())
    }

    public func paragraphStyle(font: NSFont, headIndent: CGFloat = 0, firstLineHeadIndent: CGFloat = 0,
                               spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0, multiple: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing(for: font, multiple: multiple)
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineHeadIndent
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.lineBreakMode = .byWordWrapping
        return p
    }

    public func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: fonts.body,
            .foregroundColor: palette.text,
            .paragraphStyle: paragraphStyle(font: fonts.body),
        ]
    }
}
