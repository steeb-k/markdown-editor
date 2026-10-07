//! The `template:` key of a YAML front matter block: reading it, and the edit that sets or removes it.
//!
//! Works on the text, not on the parsed document, so the edit can be computed for a text the shell holds and the
//! document does not (and a front matter block is simple enough to find by hand: `---` on the first line, the next
//! `---` or `...` line closes it, the same as the parser's).

/// Where a front matter block is. All offsets are bytes.
struct Block {
    /// After the byte order mark, where the opening line starts.
    start: usize,
    /// The first byte after the opening line.
    body: usize,
    /// The start of the closing line.
    close: usize,
    /// The first byte after the closing line (and its line ending).
    end: usize,
}

/// `line` without its line ending.
fn bare(line: &str) -> &str {
    line.strip_suffix('\n').map_or(line, |l| l.strip_suffix('\r').unwrap_or(l))
}

/// Whether a line (without its ending) closes a block: three dashes or dots and only spaces after them, as
/// pulldown-cmark's `scan_closing_metadata_block` has it (a tab after them makes it text).
fn is_closer(line: &str) -> bool {
    let rest = line.strip_prefix("---").or_else(|| line.strip_prefix("..."));
    rest.is_some_and(|r| r.bytes().all(|b| b == b' '))
}

/// The block exactly when the parser sees one, so that the key is only ever read from, and written into, what the
/// preview treats as front matter. Besides the delimiters, the parser refuses a block whose first line is blank or is
/// already the closer: `---`, a blank line, a paragraph and a later `---` are two thematic breaks around text, and a
/// `template:` line written before the second would have become a setext heading in the document.
fn find_block(text: &str) -> Option<Block> {
    let start = if text.starts_with('\u{feff}') { '\u{feff}'.len_utf8() } else { 0 };
    let mut lines = text[start..].split_inclusive('\n');
    let first = lines.next()?;
    if bare(first).trim_end() != "---" {
        return None;
    }
    let body = start + first.len();
    let mut at = body;
    for (i, line) in lines.enumerate() {
        let t = bare(line);
        if i == 0 && (t.bytes().all(|b| b == b' ' || b == b'\t') || is_closer(t)) {
            return None;
        }
        if is_closer(t) {
            return Some(Block { start, body, close: at, end: at + line.len() });
        }
        at += line.len();
    }
    None
}

/// The byte range of the first top-level `template:` line of the block body, with its line ending, and the value text.
fn find_key(text: &str, b: &Block) -> Option<(usize, usize, String)> {
    let mut at = b.body;
    for line in text[b.body..b.close].split_inclusive('\n') {
        if let Some(rest) = line.strip_prefix("template:") {
            return Some((at, at + line.len(), read_value(bare(rest))));
        }
        at += line.len();
    }
    None
}

/// A YAML scalar as a name: quoted (`"a \"b\""`, `'it''s'`) or bare up to a ` #` comment, trimmed.
fn read_value(raw: &str) -> String {
    let v = raw.trim();
    let mut chars = v.chars();
    match chars.next() {
        Some('"') => {
            let mut out = String::new();
            let mut escaped = false;
            for c in chars {
                match (escaped, c) {
                    (true, c) => {
                        out.push(c);
                        escaped = false;
                    }
                    (false, '\\') => escaped = true,
                    (false, '"') => break,
                    (false, c) => out.push(c),
                }
            }
            out.trim().to_owned()
        }
        Some('\'') => {
            let mut out = String::new();
            let mut rest = chars.peekable();
            while let Some(c) = rest.next() {
                if c == '\'' {
                    if rest.peek() == Some(&'\'') {
                        rest.next();
                        out.push('\'');
                        continue;
                    }
                    break;
                }
                out.push(c);
            }
            out.trim().to_owned()
        }
        _ => v.split(" #").next().unwrap_or("").trim().to_owned(),
    }
}

/// A name as a YAML scalar: bare when that reads back as the same name, double-quoted otherwise.
fn write_value(name: &str) -> String {
    let plain = !name.is_empty()
        && name == name.trim()
        && !name.starts_with(|c: char| "\"'[]{}&*!|>%@`-?:#,".contains(c))
        && !name.contains(": ")
        && !name.contains(" #")
        && !name.ends_with(':')
        && !name.chars().any(char::is_control);
    if plain {
        name.to_owned()
    } else {
        let escaped: String = name
            .chars()
            .filter(|c| !c.is_control())
            .flat_map(|c| if matches!(c, '"' | '\\') { vec!['\\', c] } else { vec![c] })
            .collect();
        format!("\"{escaped}\"")
    }
}

/// The `template:` value of the front matter block at the very start of `text` (after a byte order mark), if there is
/// one: quoted or bare, trimmed, never empty.
pub(crate) fn front_matter_template(text: &str) -> Option<String> {
    let block = find_block(text)?;
    find_key(text, &block).map(|k| k.2).filter(|v| !v.is_empty())
}

/// The edit that makes `name` the block's `template:` (`None`, or a blank name, removes the key and a block that is
/// then empty): a byte range of `text` and its replacement. `None` when `text` already says that. The file's line
/// ending is kept; a block that has to be made is followed by a blank line unless the text already starts with one.
pub(crate) fn set_front_matter_template(text: &str, name: Option<&str>) -> Option<(usize, usize, String)> {
    let name = name.map(str::trim).filter(|n| !n.is_empty());
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let Some(block) = find_block(text) else {
        let name = name?;
        let rest = &text[text.starts_with('\u{feff}') as usize * '\u{feff}'.len_utf8()..];
        let blank = rest.is_empty() || rest.starts_with(['\n', '\r']);
        let start = text.len() - rest.len();
        let gap = if blank { "" } else { eol };
        return Some((start, start, format!("---{eol}template: {}{eol}---{eol}{gap}", write_value(name))));
    };
    let existing = find_key(text, &block);
    match (name, existing) {
        (Some(name), Some((from, to, current))) => {
            if current == name {
                return None;
            }
            // The line's text only: its ending stays as it is.
            let end = from + bare(&text[from..to]).len();
            Some((from, end, format!("template: {}", write_value(name))))
        }
        (Some(name), None) => {
            let line_eol = if text[block.start..block.body].ends_with("\r\n") { "\r\n" } else { "\n" };
            Some((block.close, block.close, format!("template: {}{line_eol}", write_value(name))))
        }
        (None, None) => None,
        (None, Some((from, to, _))) => {
            let others = text[block.body..from].trim().is_empty() && text[to..block.close].trim().is_empty();
            if !others {
                // When the key is the block's first line, the blank lines after it go too: a block whose first line
                // is blank is no block to the parser, and the keys left in it would show as text.
                let mut to = to;
                if from == block.body {
                    for line in text[to..block.close].split_inclusive('\n') {
                        if !bare(line).bytes().all(|b| b == b' ' || b == b'\t') {
                            break;
                        }
                        to += line.len();
                    }
                }
                return Some((from, to, String::new()));
            }
            // Nothing else in the block: it goes, and the blank line that was made for it.
            let after = &text[block.end..];
            // Unless the text after it would then open a front matter block of its own.
            let blank = after
                .split_inclusive('\n')
                .next()
                .filter(|l| bare(l).trim().is_empty() && !l.is_empty() && find_block(&after[l.len()..]).is_none());
            Some((block.start, block.end + blank.map_or(0, str::len), String::new()))
        }
    }
}
