//! A small sanitizer for the raw HTML a Markdown document may contain, for fragments that leave
//! the preview (the clipboard). It is a filter, not an HTML parser: it recognises tags well
//! enough to drop what could run or load code, and passes everything else through untouched.
//!
//! Dropped: `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>` (and `<applet>`, `<base>`,
//! `<link>`, `<meta>`) with the content of those that have one; every attribute whose name starts
//! with `on`; `srcdoc`; and URL attributes (`href`, `src`, ...) whose scheme is `javascript:`,
//! `vbscript:` or `data:` (other than a raster image).

/// Elements removed together with their content.
const BLOCKED: [&str; 6] = ["script", "style", "iframe", "object", "embed", "applet"];
/// Elements removed without content (they have none).
const BLOCKED_VOID: [&str; 3] = ["base", "link", "meta"];
const URL_ATTRIBUTES: [&str; 9] =
    ["href", "src", "xlink:href", "action", "formaction", "data", "poster", "background", "srcset"];

/// State carried across the pieces of one block (an inline `<script>` and its closing tag are
/// separate events).
#[derive(Debug, Default, Clone)]
pub(crate) struct HtmlFilter {
    /// The blocked element whose content is being dropped, and how deep it nests.
    skipping: Option<(&'static str, u32)>,
}

impl HtmlFilter {
    pub fn is_skipping(&self) -> bool {
        self.skipping.is_some()
    }

    /// End of a block: an element left open does not swallow what comes after.
    pub fn reset(&mut self) {
        self.skipping = None;
    }

    pub fn filter(&mut self, html: &str) -> String {
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
            if html[i..].starts_with("<!--") {
                match html[i + 4..].find("-->") {
                    Some(end) => {
                        let stop = i + 4 + end + 3;
                        if self.skipping.is_none() {
                            out.push_str(&html[i..stop]);
                        }
                        i = stop;
                    }
                    None => {
                        // An unterminated comment would swallow what follows in a browser: it is
                        // text, and what follows is filtered as usual.
                        if self.skipping.is_none() {
                            out.push_str("&lt;");
                        }
                        i += 1;
                    }
                }
                continue;
            }
            let closing = b.get(i + 1) == Some(&b'/');
            let name_start = i + 1 + usize::from(closing);
            // As the HTML tokenizer reads a tag name: up to whitespace, `/` or `>`.
            let name_len = b[name_start.min(b.len())..]
                .iter()
                .take_while(|c| !c.is_ascii_whitespace() && **c != b'/' && **c != b'>')
                .count();
            let starts_tag = name_len > 0 && b[name_start].is_ascii_alphabetic();
            if !starts_tag {
                // `<!DOCTYPE>`, `<?php ?>`, CDATA and a lone `<`: pass `<` on as text.
                if self.skipping.is_none() {
                    if b.get(i + 1).is_some_and(|c| matches!(c, b'!' | b'?')) {
                        let end = html[i..].find('>').map_or(html.len(), |e| i + e + 1);
                        out.push_str(&html[i..end]);
                        i = end;
                        continue;
                    }
                    out.push('<');
                }
                i += 1;
                continue;
            }
            let Some(end) = tag_end(html, name_start + name_len) else {
                // A tag that never closes: make it text rather than let it swallow what follows.
                if self.skipping.is_none() {
                    out.push_str("&lt;");
                }
                i += 1;
                continue;
            };
            let name = html[name_start..name_start + name_len].to_ascii_lowercase();
            let self_closing = html[..end].trim_end_matches('>').ends_with('/');
            self.tag(&mut out, html, i, name_start + name_len, end, &name, closing, self_closing);
            i = end;
        }
        out
    }

    #[allow(clippy::too_many_arguments)]
    fn tag(
        &mut self,
        out: &mut String,
        html: &str,
        start: usize,
        attrs_start: usize,
        end: usize,
        name: &str,
        closing: bool,
        self_closing: bool,
    ) {
        if let Some((blocked, depth)) = self.skipping {
            if name == blocked {
                if closing {
                    self.skipping = if depth <= 1 { None } else { Some((blocked, depth - 1)) };
                } else if !self_closing {
                    self.skipping = Some((blocked, depth + 1));
                }
            }
            return;
        }
        if let Some(blocked) = BLOCKED.iter().find(|n| **n == name) {
            if !closing && !self_closing {
                self.skipping = Some((blocked, 1));
            }
            return;
        }
        if BLOCKED_VOID.contains(&name) {
            return;
        }
        if closing {
            out.push_str(&html[start..end]);
            return;
        }
        out.push_str(&html[start..attrs_start]);
        let tag_end = if self_closing { end - 2 } else { end - 1 };
        rewrite_attributes(out, &html[attrs_start..tag_end.max(attrs_start)]);
        out.push_str(if self_closing { " />" } else { ">" });
    }
}

/// Index just past the `>` that closes the tag whose name ends at `from`, honouring quotes.
fn tag_end(html: &str, from: usize) -> Option<usize> {
    let b = html.as_bytes();
    let mut quote: Option<u8> = None;
    for (k, &c) in b[from..].iter().enumerate() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None => match c {
                b'"' | b'\'' => quote = Some(c),
                b'>' => return Some(from + k + 1),
                _ => {}
            },
        }
    }
    None
}

/// Writes the attributes of `attrs` (the text between the tag name and the `>`) that are safe.
fn rewrite_attributes(out: &mut String, attrs: &str) {
    let b = attrs.as_bytes();
    let mut i = 0;
    while i < b.len() {
        while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b'/') {
            i += 1;
        }
        let name_start = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' && b[i] != b'/' {
            i += 1;
        }
        if i == name_start {
            break;
        }
        let name = &attrs[name_start..i];
        let mut j = i;
        while j < b.len() && b[j].is_ascii_whitespace() {
            j += 1;
        }
        let mut value: Option<&str> = None;
        let mut stop = i;
        if j < b.len() && b[j] == b'=' {
            j += 1;
            while j < b.len() && b[j].is_ascii_whitespace() {
                j += 1;
            }
            if j < b.len() && (b[j] == b'"' || b[j] == b'\'') {
                let q = b[j];
                let close = attrs[j + 1..].bytes().position(|c| c == q).map_or(b.len(), |p| j + 1 + p);
                value = Some(&attrs[j + 1..close]);
                stop = (close + 1).min(b.len());
            } else {
                let vs = j;
                while j < b.len() && !b[j].is_ascii_whitespace() {
                    j += 1;
                }
                value = Some(&attrs[vs..j]);
                stop = j;
            }
        }
        i = stop.max(i);
        let lower = name.to_ascii_lowercase();
        let dangerous = lower.starts_with("on")
            || lower == "srcdoc"
            || (URL_ATTRIBUTES.contains(&lower.as_str()) && value.is_some_and(is_dangerous_url));
        if !dangerous {
            out.push(' ');
            out.push_str(&attrs[name_start..i]);
        }
    }
}

/// A URL that would run script or load a document when followed: `javascript:`, `vbscript:`
/// and `data:` (except raster images), however it is spelled (whitespace, control characters
/// and character references inside the scheme are ignored, as browsers do).
pub(crate) fn is_dangerous_url(url: &str) -> bool {
    let mut s = String::with_capacity(url.len().min(64));
    let mut chars = url.chars().peekable();
    while let Some(c) = chars.next() {
        if s.len() > 40 {
            break;
        }
        if c == '&' {
            let mut reference = String::new();
            while let Some(&n) = chars.peek() {
                if reference.len() > 10 {
                    break;
                }
                chars.next();
                if n == ';' {
                    break;
                }
                reference.push(n);
            }
            let decoded = match reference.as_str() {
                "colon" => Some(':'),
                "Tab" | "NewLine" => None,
                r if r.starts_with("#x") || r.starts_with("#X") => u32::from_str_radix(&r[2..], 16).ok().and_then(char::from_u32),
                r if r.starts_with('#') => r[1..].parse::<u32>().ok().and_then(char::from_u32),
                _ => Some('&'),
            };
            if let Some(d) = decoded
                && (d as u32) > 0x20
            {
                s.push(d.to_ascii_lowercase());
            }
            continue;
        }
        if (c as u32) > 0x20 && c != '\u{7f}' {
            s.push(c.to_ascii_lowercase());
        }
    }
    if s.starts_with("javascript:") || s.starts_with("vbscript:") {
        return true;
    }
    if let Some(rest) = s.strip_prefix("data:") {
        return !["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"].iter().any(|t| rest.starts_with(t));
    }
    false
}
