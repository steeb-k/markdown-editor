//! The sanitizer for the raw HTML a Markdown document may contain, for HTML that leaves the
//! preview (the clipboard: whatever is pasted into Mail, Pages or a web form). It is an
//! **allowlist**: an element is kept only if it is in [`ALLOWED`], an attribute only if it is in
//! [`GLOBAL_ATTRIBUTES`] or the element's own list, a URL only if it is relative or uses one of
//! [`SAFE_SCHEMES`] (and `data:` only for a raster image in `src`). Everything else is dropped:
//!
//! * elements that are not allowed lose their tags and keep their content (`<form>`, `<button>`,
//!   `<custom-thing>`, `<html>`, `<meta>`...), except those in [`DROPPED_WITH_CONTENT`] (script,
//!   style, frames, plugins, raw-text elements, and SVG and MathML, whose foreign-content parsing
//!   rules differ from HTML's), which go with their content;
//! * comments, `<!DOCTYPE>`, CDATA and processing instructions are dropped, ended where a browser
//!   ends them (`<!-->` is a whole comment; `--!>` also ends one);
//! * `style` attributes are kept only when they cannot load anything or run anything.
//!
//! It does not copy tags through: it reads each tag as the HTML tokenizer would (the tag name to
//! whitespace, `/` or `>`; quotes only around attribute values) and writes a new, normalised tag
//! (`<a href="...">`), so what a browser reads from the output is what the filter decided on. A
//! `<` that does not start a tag the filter can read to its end is written as `&lt;`. Elements
//! the filter opened in a paragraph are closed at the paragraph's end; elements an HTML block
//! opened and never closed are closed at the end of the fragment.

/// Elements kept (with only their allowed attributes).
const ALLOWED: &[&str] = &[
    "a", "abbr", "b", "bdi", "bdo", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup",
    "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5",
    "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s", "samp",
    "small", "span", "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead",
    "time", "tr", "tt", "u", "ul", "var", "wbr",
];

/// The allowed elements that may stand inside a paragraph (what inline HTML may open).
const PHRASING: &[&str] = &[
    "a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "del", "dfn", "em", "i", "img", "ins", "kbd", "mark", "q",
    "rp", "rt", "ruby", "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "time", "tt", "u", "var", "wbr",
];

/// Elements that have no content and no end tag.
const VOID: &[&str] = &["br", "col", "hr", "img", "wbr"];

/// Elements removed together with everything inside them.
const DROPPED_WITH_CONTENT: &[&str] = &[
    "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "noscript", "noembed",
    "noframes", "template", "textarea", "title", "xmp", "plaintext", "svg", "math", "select", "head",
];

/// Attributes any kept element may have.
const GLOBAL_ATTRIBUTES: &[&str] = &["id", "class", "title", "lang", "dir", "align", "style"];

/// Attributes particular elements may have besides the global ones.
fn element_attributes(element: &str) -> &'static [&'static str] {
    match element {
        "a" => &["href", "name"],
        "img" => &["src", "alt", "width", "height"],
        "td" | "th" => &["colspan", "rowspan", "valign"],
        "col" | "colgroup" => &["span"],
        "ol" => &["start", "reversed", "type"],
        "ul" => &["type"],
        "li" => &["value"],
        "blockquote" | "q" | "del" | "ins" => &["cite"],
        "time" => &["datetime"],
        "details" => &["open"],
        _ => &[],
    }
}

/// Attributes whose value is a URL, checked with [`is_safe_url`].
const URL_ATTRIBUTES: &[&str] = &["href", "src", "cite"];

/// Schemes a link or a picture may use. Anything else (`javascript:`, `vbscript:`, `file:`,
/// `blob:`, an application's own scheme...) is dropped: a pasted document should not be able to
/// start a program with a click.
const SAFE_SCHEMES: &[&str] = &["http", "https", "mailto", "tel"];

/// Raster images a `data:` URL in `src` may hold (never SVG, which can carry script).
const SAFE_DATA_IMAGES: &[&str] = &["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"];

#[derive(Debug, Clone)]
struct Open {
    name: String,
    /// Opened by inline HTML in a paragraph (closed at its end) rather than by an HTML block.
    inline: bool,
    /// How deep in the renderer's containers (quotes, list items, notes) it was opened: it is
    /// closed when that container ends.
    depth: u32,
    /// One of the renderer's own inline elements (`<em>` for `*x*`...): raw end tags cannot close
    /// it or anything outside it, and what raw HTML opened inside it closes with it.
    own: bool,
}

/// State carried across the pieces of one render (an inline `<script>` and its closing tag are
/// separate events; an HTML block may open a `<div>` that a later one closes).
#[derive(Debug, Default, Clone)]
pub(crate) struct HtmlFilter {
    /// The element whose content is being dropped, and how deep it nests.
    skipping: Option<(&'static str, u32)>,
    /// Kept elements opened and not yet closed, innermost last.
    open: Vec<Open>,
    /// The renderer's container depth now.
    depth: u32,
}

impl HtmlFilter {
    /// The renderer opened a container (a quote, a list item, a note).
    pub fn enter(&mut self) {
        self.depth += 1;
    }

    /// The renderer opened one of its own inline elements (emphasis, a link...).
    pub fn open_own(&mut self, name: &str) {
        self.open.push(Open { name: name.to_owned(), inline: true, depth: self.depth, own: true });
    }

    /// The renderer is about to close its innermost own inline element: end tags for what raw
    /// HTML opened inside it.
    pub fn close_own(&mut self) -> String {
        let out = self.close_while(|o| !o.own);
        // The renderer's own element: it writes its end tag itself.
        if self.open.last().is_some_and(|o| o.own) {
            self.open.pop();
        }
        out
    }

    /// The container ends: end tags for what raw HTML opened inside it.
    pub fn leave(&mut self) -> String {
        let depth = self.depth;
        let out = self.close_while(|o| o.depth >= depth);
        self.depth = self.depth.saturating_sub(1);
        out
    }

    /// Pops the innermost elements while `more` holds, with end tags for those raw HTML opened.
    fn close_while(&mut self, more: impl Fn(&Open) -> bool) -> String {
        let mut out = String::new();
        while self.open.last().is_some_and(&more) {
            let o = self.open.pop().expect("checked");
            if !o.own {
                out.push_str("</");
                out.push_str(&o.name);
                out.push('>');
            }
        }
        out
    }

    pub fn is_skipping(&self) -> bool {
        self.skipping.is_some()
    }

    /// End of a paragraph, heading, cell or item: an element left open there does not swallow
    /// what comes after. Returns the end tags for the elements inline HTML opened in it.
    pub fn end_block(&mut self) -> String {
        self.skipping = None;
        self.close_while(|o| o.inline)
    }

    /// End of an HTML block: an element it left open whose content is being dropped stops here.
    pub fn end_html_block(&mut self) {
        self.skipping = None;
    }

    /// End of the fragment: end tags for everything still open.
    pub fn finish(&mut self) -> String {
        self.skipping = None;
        self.close_while(|_| true)
    }

    /// Filters one piece of raw HTML: an inline HTML event (`inline`) or an HTML block.
    pub fn filter(&mut self, html: &str, inline: bool) -> String {
        let b = html.as_bytes();
        let mut out = String::with_capacity(html.len());
        let mut i = 0;
        while i < b.len() {
            let Some(rel) = html[i..].find('<') else {
                if self.skipping.is_none() {
                    out.push_str(&html[i..]);
                }
                break;
            };
            if self.skipping.is_none() {
                out.push_str(&html[i..i + rel]);
            }
            i += rel;
            let next = b.get(i + 1).copied();
            // Comments and the other markup declarations a browser reads as comments: dropped,
            // to where the browser ends them.
            if html[i..].starts_with("<!--") {
                i = comment_end(html, i + 4);
                continue;
            }
            if matches!(next, Some(b'!' | b'?')) {
                i = html[i..].find('>').map_or(b.len(), |e| i + e + 1);
                continue;
            }
            let closing = next == Some(b'/');
            let name_start = i + 1 + usize::from(closing);
            if !b.get(name_start).is_some_and(u8::is_ascii_alphabetic) {
                if closing && b.get(name_start) == Some(&b'>') {
                    // `</>` is nothing to a browser.
                    i = name_start + 1;
                } else if closing {
                    // `</3...>` is a bogus comment to a browser.
                    i = html[i..].find('>').map_or(b.len(), |e| i + e + 1);
                } else {
                    // A lone `<`: text.
                    if self.skipping.is_none() {
                        out.push_str("&lt;");
                    }
                    i += 1;
                }
                continue;
            }
            let Some(tag) = read_tag(html, name_start) else {
                // A tag that never ends here: text, rather than let it swallow what follows.
                if self.skipping.is_none() {
                    out.push_str("&lt;");
                }
                i += 1;
                continue;
            };
            i = tag.end;
            self.tag(&mut out, &tag, closing, inline);
        }
        out
    }

    fn tag(&mut self, out: &mut String, tag: &Tag, closing: bool, inline: bool) {
        let name = tag.name.as_str();
        if let Some((dropped, depth)) = self.skipping {
            if name == dropped {
                if closing {
                    self.skipping = if depth <= 1 { None } else { Some((dropped, depth - 1)) };
                } else if !tag.self_closing {
                    self.skipping = Some((dropped, depth + 1));
                }
            }
            return;
        }
        if let Some(dropped) = DROPPED_WITH_CONTENT.iter().find(|n| **n == name) {
            // `<svg/>` and the like have no content to drop.
            if !closing && !tag.self_closing {
                self.skipping = Some((dropped, 1));
            }
            return;
        }
        let Some(&allowed) = ALLOWED.iter().find(|n| **n == name) else { return };
        // Inside a paragraph (or a heading, a cell...) only phrasing content: a `<div>` there would
        // make a browser close the paragraph and leave the renderer's own `</p>` stray.
        if inline && !PHRASING.contains(&allowed) {
            return;
        }
        let void = VOID.contains(&allowed);
        if closing {
            if void {
                return;
            }
            // Only an element the filter opened (a stray end tag could close the renderer's own),
            // and the elements opened inside it with it, so the output stays nested.
            let depth = self.depth;
            // Not across one of the renderer's own elements.
            let floor = self.open.iter().rposition(|o| o.own).map_or(0, |k| k + 1);
            if let Some(k) = self.open[floor..].iter().rposition(|o| o.name == allowed && o.inline == inline && o.depth == depth).map(|k| k + floor) {
                for o in self.open.drain(k..).rev() {
                    out.push_str("</");
                    out.push_str(&o.name);
                    out.push('>');
                }
            }
            return;
        }
        out.push('<');
        out.push_str(allowed);
        let own = element_attributes(allowed);
        for (attr, value) in &tag.attributes {
            let attr = attr.as_str();
            if !(GLOBAL_ATTRIBUTES.contains(&attr) || own.contains(&attr)) {
                continue;
            }
            let value = value.as_deref().unwrap_or("");
            if URL_ATTRIBUTES.contains(&attr) && !is_safe_url(value, attr == "src") {
                continue;
            }
            if attr == "style" && !is_safe_style(value) {
                continue;
            }
            out.push(' ');
            out.push_str(attr);
            out.push_str("=\"");
            for c in value.chars() {
                match c {
                    '"' => out.push_str("&quot;"),
                    '<' => out.push_str("&lt;"),
                    '>' => out.push_str("&gt;"),
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        out.push_str(if void { " />" } else { ">" });
        if !void {
            self.open.push(Open { name: allowed.to_owned(), inline, depth: self.depth, own: false });
        }
    }
}

/// Where a comment whose `<!--` ends just before `from` ends, as a browser reads it: `<!-->` and
/// `<!--->` are whole comments, otherwise the first `-->` or `--!>`, otherwise the end.
fn comment_end(html: &str, from: usize) -> usize {
    let rest = &html[from..];
    if rest.starts_with('>') {
        return from + 1;
    }
    if rest.starts_with("->") {
        return from + 2;
    }
    let a = rest.find("-->").map(|k| from + k + 3);
    let b = rest.find("--!>").map(|k| from + k + 4);
    match (a, b) {
        (Some(a), Some(b)) => a.min(b),
        (Some(x), None) | (None, Some(x)) => x,
        (None, None) => html.len(),
    }
}

struct Tag {
    /// Lower case.
    name: String,
    /// Names in lower case, in order; the first of a repeated name wins (as in a browser).
    attributes: Vec<(String, Option<String>)>,
    self_closing: bool,
    /// Just past the `>`.
    end: usize,
}

fn is_html_space(c: u8) -> bool {
    matches!(c, b'\t' | b'\n' | b'\x0c' | b'\r' | b' ')
}

/// Reads a tag whose name starts at `name_start` the way the HTML tokenizer does (the states
/// "tag name" to "after attribute value (quoted)"). `None` when the input ends inside it.
fn read_tag(html: &str, name_start: usize) -> Option<Tag> {
    let b = html.as_bytes();
    let mut i = name_start;
    while i < b.len() && !is_html_space(b[i]) && b[i] != b'/' && b[i] != b'>' {
        i += 1;
    }
    let name = html[name_start..i].to_ascii_lowercase();
    let mut attributes: Vec<(String, Option<String>)> = Vec::new();
    let mut self_closing = false;
    loop {
        // Before attribute name.
        while i < b.len() && (is_html_space(b[i]) || b[i] == b'/') {
            self_closing = b[i] == b'/';
            i += 1;
        }
        let &c = b.get(i)?;
        if c == b'>' {
            return Some(Tag { name, attributes, self_closing, end: i + 1 });
        }
        self_closing = false;
        // Attribute name: a leading `=` is part of it.
        let start = i;
        i += 1;
        while i < b.len() && !is_html_space(b[i]) && b[i] != b'/' && b[i] != b'>' && b[i] != b'=' {
            i += 1;
        }
        let attr = html[start..i].to_ascii_lowercase();
        // After attribute name.
        while i < b.len() && is_html_space(b[i]) {
            i += 1;
        }
        let mut value = None;
        if b.get(i) == Some(&b'=') {
            i += 1;
            while i < b.len() && is_html_space(b[i]) {
                i += 1;
            }
            match b.get(i)? {
                q @ (b'"' | b'\'') => {
                    let close = html[i + 1..].find(*q as char)? + i + 1;
                    value = Some(html[i + 1..close].to_owned());
                    i = close + 1;
                }
                b'>' => value = Some(String::new()),
                _ => {
                    let vs = i;
                    while i < b.len() && !is_html_space(b[i]) && b[i] != b'>' {
                        i += 1;
                    }
                    value = Some(html[vs..i].to_owned());
                }
            }
        }
        if !attributes.iter().any(|(n, _)| *n == attr) {
            attributes.push((attr, value));
        }
    }
}

/// `text` as a browser would read a URL's scheme or a style's functions from it: character
/// references decoded, whitespace and control characters removed, in lower case.
fn decoded_text(text: &str) -> String {
    let mut s = String::with_capacity(text.len().min(64));
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '&' {
            let mut reference = String::new();
            while let Some(&n) = chars.peek() {
                if reference.len() > 12 || !(n.is_ascii_alphanumeric() || n == '#' || n == ';') {
                    break;
                }
                chars.next();
                if n == ';' {
                    break;
                }
                reference.push(n);
            }
            let decoded = match reference.to_ascii_lowercase().as_str() {
                "colon" => Some(':'),
                "tab" | "newline" | "nbsp" => None,
                "sol" => Some('/'),
                "quest" => Some('?'),
                "num" => Some('#'),
                r if r.starts_with("#x") => u32::from_str_radix(&r[2..], 16).ok().and_then(char::from_u32),
                r if r.starts_with('#') => r[1..].parse::<u32>().ok().and_then(char::from_u32),
                // An unknown reference: keep it as written (it cannot form a scheme's letters).
                _ => Some('&'),
            };
            if let Some(d) = decoded
                && (d as u32) > 0x20
                && d != '\u{7f}'
            {
                s.push(d.to_ascii_lowercase());
            }
            continue;
        }
        if (c as u32) > 0x20 && c != '\u{7f}' {
            s.push(c.to_ascii_lowercase());
        }
    }
    s
}

/// A URL that may stay in sanitized HTML: relative (a path, `#fragment`, `?query`, `//host/...`),
/// or with a scheme in [`SAFE_SCHEMES`]; for a picture's `src` (`image`), also a `data:` URL of a
/// raster image. Everything else, however it is spelled, is not.
pub(crate) fn is_safe_url(url: &str, image: bool) -> bool {
    // Decoded and stripped of whitespace and control characters (a browser removes tabs and
    // newlines; the other controls are removed too, which can only make a scheme appear where a
    // browser would see none, so only errs towards dropping). The whole URL: a scheme may be long.
    let s = decoded_text(url);
    // A scheme is a letter, then letters, digits, `+`, `-` and `.`, then `:`; a browser reads
    // anything else as a relative URL.
    let end = s.find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))).unwrap_or(s.len());
    if end == 0 || !s[end..].starts_with(':') || !s.as_bytes()[0].is_ascii_alphabetic() {
        return true;
    }
    let (scheme, colon) = (&s[..end], end);
    if SAFE_SCHEMES.contains(&scheme) {
        return true;
    }
    if image && scheme == "data" {
        let rest = &s[colon + 1..];
        return SAFE_DATA_IMAGES.iter().any(|t| rest.strip_prefix(t).is_some_and(|after| after.starts_with([';', ','])));
    }
    false
}

/// A `style` attribute that can neither load a resource nor run anything: no `url(`, `image(`,
/// `image-set(`, `expression(`, `@import`, behaviours or bindings, and no escapes or comments that
/// could spell one.
fn is_safe_style(style: &str) -> bool {
    if style.len() > 2000 {
        return false;
    }
    // Decoded and without whitespace, so `u r l (` and `&#117;rl(` cannot hide.
    let lower = decoded_text(style);
    if lower.contains(['\\', '<', '>', '@']) || lower.contains("/*") {
        return false;
    }
    !["url(", "image(", "image-set(", "expression", "javascript", "behavior", "binding", "cross-fade(", "element("]
        .iter()
        .any(|bad| lower.contains(bad))
}
