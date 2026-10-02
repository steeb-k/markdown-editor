import AppKit
import CoreText

/// The set of faces the styler needs for one font choice and size.
public final class FontSet {
    public let body: NSFont
    public let mono: NSFont
    public let size: CGFloat
    public let bundled: Bool
    private var cache: [String: NSFont] = [:]

    init(body: NSFont, mono: NSFont, size: CGFloat, bundled: Bool) {
        self.body = body; self.mono = mono; self.size = size; self.bundled = bundled
    }

    /// `base` with extra traits and, optionally, a different size.
    public func variant(of base: NSFont, bold: Bool = false, italic: Bool = false, size: CGFloat? = nil) -> NSFont {
        let target = size ?? base.pointSize
        let key = "\(base.fontName)|\(bold)|\(italic)|\(target)"
        if let f = cache[key] { return f }
        var f = target == base.pointSize ? base : (NSFont(descriptor: base.fontDescriptor, size: target) ?? base)
        let wantBold = bold || isBold(f), wantItalic = italic || isItalic(f)
        if let named = Self.bundledFace(of: f, bold: wantBold, italic: wantItalic, size: target) {
            f = named
        } else {
            let fm = NSFontManager.shared
            if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        }
        cache[key] = f
        return f
    }

    /// The bundled faces are separate static fonts ("iAWriterMonoS-BoldItalic"); pick
    /// them by name rather than trusting trait conversion across a family AppKit may split.
    static func bundledFace(of f: NSFont, bold: Bool, italic: Bool, size: CGFloat) -> NSFont? {
        guard f.fontName.hasPrefix("iAWriter"), let dash = f.fontName.firstIndex(of: "-") else { return nil }
        let family = f.fontName[..<dash]
        let style = (bold ? "Bold" : "") + (italic ? "Italic" : "")
        return NSFont(name: "\(family)-\(style.isEmpty ? "Regular" : style)", size: size)
    }

    public static func isMonospaced(_ f: NSFont) -> Bool {
        f.isFixedPitch || f.fontDescriptor.symbolicTraits.contains(.monoSpace) || f.fontName.hasPrefix("iAWriterMono")
    }

    public func isBold(_ f: NSFont) -> Bool {
        f.fontName.hasPrefix("iAWriter") ? f.fontName.contains("Bold") : NSFontManager.shared.traits(of: f).contains(.boldFontMask)
    }
    public func isItalic(_ f: NSFont) -> Bool {
        f.fontName.hasPrefix("iAWriter") ? f.fontName.contains("Italic") : NSFontManager.shared.traits(of: f).contains(.italicFontMask)
    }
}

public enum FontStore {
    static let postScriptNames: [FontChoice: String] = [
        .iaMono: "iAWriterMonoS-Regular",
        .iaDuo: "iAWriterDuoS-Regular",
        .iaQuattro: "iAWriterQuattroS-Regular",
    ]

    /// Registers the bundled fonts when they are not registered already (the bundle does it
    /// through `ATSApplicationFontsPath`; this covers other hosts). Missing files are fine.
    @discardableResult
    public static func registerBundledFonts(in bundle: Bundle = .main) -> Bool {
        if NSFont(name: "iAWriterMonoS-Regular", size: 12) != nil { return true }
        guard let dir = bundle.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        let ttfs = files.filter { $0.pathExtension.lowercased() == "ttf" }
        guard !ttfs.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(ttfs as CFArray, .process, true, nil)
        return NSFont(name: "iAWriterMonoS-Regular", size: 12) != nil
    }

    public static var bundledFontsAvailable: Bool { NSFont(name: "iAWriterMonoS-Regular", size: 12) != nil }

    /// System fallbacks are used silently when a face is missing.
    public static func fonts(choice: FontChoice, customFamily: String, size: CGFloat) -> FontSet {
        let systemMono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let iaMono = NSFont(name: "iAWriterMonoS-Regular", size: size)
        var bundled = false
        var body: NSFont
        switch choice {
        case .iaMono, .iaDuo, .iaQuattro:
            if let f = NSFont(name: postScriptNames[choice]!, size: size) { body = f; bundled = true } else { body = systemMono }
        case .systemMono:
            body = systemMono
        case .systemSerif:
            let base = NSFont.systemFont(ofSize: size)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { body = f } else {
                body = NSFont(name: "Times New Roman", size: size) ?? base
            }
        case .custom:
            if !customFamily.isEmpty,
               let f = NSFontManager.shared.font(withFamily: customFamily, traits: [], weight: 5, size: size) {
                body = f
            } else {
                body = NSFont.systemFont(ofSize: size)
            }
        }
        // Code and tables are monospaced even when the writing font is proportional.
        let mono: NSFont = FontSet.isMonospaced(body) ? body : (iaMono ?? systemMono)
        return FontSet(body: body, mono: mono, size: size, bundled: bundled)
    }

    public static var installedFamilies: [String] { NSFontManager.shared.availableFontFamilies }
}
