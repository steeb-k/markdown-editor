import AppKit
import MarkdownCore

/// Copy As: the selection (or the whole document) as HTML, or as rich text. Both are rendered by
/// the core from its own `Document`, never read back from the text view, so nothing the editor
/// paints over the text (focus dimming, parts of speech, authorship colours, markup dimming) and
/// nothing the file carries (the annotation block) can reach them. The app's private authorship
/// pasteboard type is not written: marks are about the Markdown source, not its rendering.
public enum CopyAsKind: Sendable {
    case html, richText
}

extension EditorSession {
    /// The fragment the clipboard gets: sanitized (no scripts, styles, frames, event handlers or
    /// `javascript:` links), clean (no `data-line`), unhighlighted (the classes mean nothing outside
    /// the preview). An empty `range` is the whole document. Waits for the analysis queue to
    /// catch up with the text (a command that needs a current analysis, PLAN "Threading").
    public func clipboardHTML(range: NSRange) -> String {
        let r = Utf16Range(start: UInt32(max(0, range.location)), end: UInt32(max(0, NSMaxRange(range))))
        let options = RenderOptions(sourceLines: false, standalone: false, sanitize: true, highlight: false)
        return coordinator.sync { doc in doc.renderHtmlFragment(range: r, options: options) }
    }

    /// Copy as HTML or Rich Text to `pasteboard`; false when there is nothing to copy.
    /// - HTML: `public.html` and, as plain text, the HTML source.
    /// - Rich text: `public.html`, `public.rtf` (built from that HTML with basic styles, so Mail,
    ///   Pages and Notes paste formatted text) and the rendered text as the plain-text fallback.
    @discardableResult
    public func copyAs(_ kind: CopyAsKind, range: NSRange, to pasteboard: NSPasteboard) -> Bool {
        let fragment = clipboardHTML(range: range)
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pasteboard.clearContents()
        let flavour = "<meta charset=\"utf-8\">" + fragment
        switch kind {
        case .html:
            pasteboard.setString(flavour, forType: .html)
            pasteboard.setString(fragment, forType: .string)
        case .richText:
            let rich = RichTextBuilder.attributed(fromFragment: fragment)
            pasteboard.setString(flavour, forType: .html)
            if let rich {
                if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    pasteboard.setData(rtf, forType: .rtf)
                }
                pasteboard.setString(rich.string.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
            } else {
                pasteboard.setString(Self.plainText(ofHTML: fragment), forType: .string)
            }
        }
        return true
    }

    static func plainText(ofHTML html: String) -> String {
        var out = ""
        var inTag = false
        for c in html {
            if c == "<" { inTag = true } else if c == ">" { inTag = false } else if !inTag { out.append(c) }
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// HTML in, styled text out: what the importer makes of a fragment, given a few styles it
/// understands and the system fonts (the editor's own fonts may not exist where the text is pasted).
enum RichTextBuilder {
    static let style = """
    body { font-family: -apple-system, 'Helvetica Neue', sans-serif; font-size: 14px; line-height: 1.4; }
    h1 { font-size: 26px; } h2 { font-size: 22px; } h3 { font-size: 18px; } h4 { font-size: 16px; } h5, h6 { font-size: 14px; }
    code, pre { font-family: Menlo, monospace; font-size: 12px; }
    pre { background-color: #f3f3f1; }
    blockquote { margin-left: 18px; color: #555555; }
    a { color: #1a5ec9; }
    table, th, td { border: 1px solid #999999; } th, td { padding: 4px 8px; }
    """

    /// Main thread only (the importer is built on WebKit's text engine).
    static func attributed(fromFragment fragment: String) -> NSAttributedString? {
        // Task checkboxes are inputs, which the importer drops; say them in words.
        let withBoxes = fragment
            .replacingOccurrences(of: "<input disabled=\"\" type=\"checkbox\" checked=\"\" />", with: "\u{2611}")
            .replacingOccurrences(of: "<input disabled=\"\" type=\"checkbox\" />", with: "\u{2610}")
        let page = "<html><head><meta charset=\"utf-8\"><style>\(style)</style></head><body>\(withBoxes)</body></html>"
        guard let data = page.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let imported = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else { return nil }
        // The importer paints plain text black; pasted into a dark document it would be unreadable.
        // Leave the text colour to the destination: only links keep theirs.
        let whole = NSRange(location: 0, length: imported.length)
        imported.enumerateAttribute(.foregroundColor, in: whole, options: []) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            if color.redComponent < 0.02, color.greenComponent < 0.02, color.blueComponent < 0.02 {
                imported.removeAttribute(.foregroundColor, range: range)
            }
        }
        return imported
    }
}
