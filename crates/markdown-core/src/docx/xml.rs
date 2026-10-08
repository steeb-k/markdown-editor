//! Small helpers for writing XML by hand: escaping and the unit conversions the markup counts in.

/// `s` as XML text or attribute content: the five special characters escaped, and the control characters XML 1.0 cannot
/// carry at all dropped (a stray form feed would make the whole part unreadable).
pub(crate) fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if (c as u32) < 0x20 || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
    out
}

/// Points as twentieths of a point (the unit of spacing and indents), rounded.
pub(crate) fn twips(pt: f64) -> i64 {
    (pt * 20.0).round() as i64
}

/// Points as half-points (the unit of font sizes), rounded and never below one point.
pub(crate) fn half_points(pt: f64) -> i64 {
    ((pt * 2.0).round() as i64).max(2)
}

/// `<w:tag w:val="value"/>`.
pub(crate) fn val(tag: &str, value: impl std::fmt::Display) -> String {
    format!("<w:{tag} w:val=\"{value}\"/>")
}

pub(crate) const XML_DECLARATION: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";

/// The namespaces a part of the main document declares.
pub(crate) const NAMESPACES: &str = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" \
xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" \
xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" \
xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" \
xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"";
