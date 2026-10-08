//! The scalar keys of a YAML front matter block (`template:`, `line_width:`): reading one, and the edit that sets or
//! removes it.
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

/// The byte range of the first top-level `key:` line of the block body, with its line ending, and the value text.
fn find_key(text: &str, b: &Block, key: &str) -> Option<(usize, usize, String)> {
    find_keys(text, b, key).into_iter().next()
}

/// Every top-level line of `key`, in order (a duplicate key is read by its first line and removed with it).
fn find_keys(text: &str, b: &Block, key: &str) -> Vec<(usize, usize, String)> {
    let mut at = b.body;
    let mut out = Vec::new();
    for line in text[b.body..b.close].split_inclusive('\n') {
        if let Some(rest) = line.strip_prefix(key).and_then(|r| r.strip_prefix(':')) {
            out.push((at, at + line.len(), read_value(bare(rest))));
        }
        at += line.len();
    }
    out
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

/// The `key` value of the front matter block at the very start of `text` (after a byte order mark), if there is one:
/// quoted or bare, trimmed, never empty.
pub(crate) fn front_matter_value(text: &str, key: &str) -> Option<String> {
    let block = find_block(text)?;
    find_key(text, &block, key).map(|k| k.2).filter(|v| !v.is_empty())
}

/// The `template:` value of the front matter block.
pub(crate) fn front_matter_template(text: &str) -> Option<String> {
    front_matter_value(text, "template")
}

/// The document's own measure: `line_width:` as an integer from 30 to 160 (the range of the setting), else none.
pub(crate) fn front_matter_line_width(text: &str) -> Option<u32> {
    let v = front_matter_value(text, "line_width")?;
    if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    v.parse::<u32>().ok().filter(|n| (30..=160).contains(n))
}

/// `text` without its front matter block and the blank lines after it (a byte order mark stays): the Markdown export's
/// "leave the front matter out". Text with no block is returned as it is.
pub(crate) fn without_front_matter(text: &str) -> String {
    let Some(block) = find_block(text) else { return text.to_owned() };
    let mut rest = &text[block.end..];
    while let Some(line) = rest.split_inclusive('\n').next().filter(|l| bare(l).bytes().all(|b| b == b' ' || b == b'\t')) {
        rest = &rest[line.len()..];
    }
    format!("{}{rest}", &text[..block.start])
}

/// The edit that makes `line_width:` the given number (`None` removes the key).
pub(crate) fn set_front_matter_line_width(text: &str, width: Option<u32>) -> Option<(usize, usize, String)> {
    set_front_matter_key(text, "line_width", width.map(|w| w.to_string()).as_deref())
}

/// The edit that sets the block's `template:` (see `set_front_matter_key`).
pub(crate) fn set_front_matter_template(text: &str, name: Option<&str>) -> Option<(usize, usize, String)> {
    set_front_matter_key(text, "template", name)
}

/// The edit that makes `value` the block's `key:` (`None`, or a blank value, removes the key and a block that is
/// then empty): a byte range of `text` and its replacement. `None` when `text` already says that. The file's line
/// ending is kept; a block that has to be made is followed by a blank line unless the text already starts with one.
pub(crate) fn set_front_matter_key(text: &str, key: &str, value: Option<&str>) -> Option<(usize, usize, String)> {
    let name = value.map(str::trim).filter(|n| !n.is_empty());
    let eol = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let Some(block) = find_block(text) else {
        let name = name?;
        let rest = &text[text.starts_with('\u{feff}') as usize * '\u{feff}'.len_utf8()..];
        let blank = rest.is_empty() || rest.starts_with(['\n', '\r']);
        let start = text.len() - rest.len();
        let gap = if blank { "" } else { eol };
        return Some((start, start, format!("---{eol}{key}: {}{eol}---{eol}{gap}", write_value(name))));
    };
    let keys = find_keys(text, &block, key);
    if keys.len() > 1 {
        return set_repeated_key(text, &block, key, name, &keys);
    }
    let existing = keys.into_iter().next();
    match (name, existing) {
        (Some(name), Some((from, to, current))) => {
            if current == name {
                return None;
            }
            // The line's text only: its ending stays as it is.
            let end = from + bare(&text[from..to]).len();
            Some((from, end, format!("{key}: {}", write_value(name))))
        }
        (Some(name), None) => {
            let line_eol = if text[block.start..block.body].ends_with("\r\n") { "\r\n" } else { "\n" };
            Some((block.close, block.close, format!("{key}: {}{line_eol}", write_value(name))))
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
            Some(block_removal(text, &block))
        }
    }
}

/// Nothing else in the block: it goes, and the blank line that was made for it, unless the text after it would then
/// open a front matter block of its own.
fn block_removal(text: &str, block: &Block) -> (usize, usize, String) {
    let after = &text[block.end..];
    let blank = after
        .split_inclusive('\n')
        .next()
        .filter(|l| bare(l).trim().is_empty() && !l.is_empty() && find_block(&after[l.len()..]).is_none());
    (block.start, block.end + blank.map_or(0, str::len), String::new())
}

/// A key written more than once: the first line is read, so the first is replaced (or removed) and the others go with
/// it in the same edit, else a removal would leave the second line to take effect. The lines of other keys between
/// them stay; with none of them left the block goes as a whole.
fn set_repeated_key(text: &str, block: &Block, key: &str, name: Option<&str>, keys: &[(usize, usize, String)]) -> Option<(usize, usize, String)> {
    let (first, last) = (keys[0].0, keys[keys.len() - 1].1);
    let is_key = |at: usize| keys.iter().any(|k| k.0 == at);
    let mut kept = String::new();
    let mut at = first;
    for line in text[first..last].split_inclusive('\n') {
        if !is_key(at) {
            kept.push_str(line);
        }
        at += line.len();
    }
    if let Some(name) = name {
        let line_eol = if text[block.start..block.body].ends_with("\r\n") { "\r\n" } else { "\n" };
        return Some((first, last, format!("{key}: {}{line_eol}{kept}", write_value(name))));
    }
    let others = !kept.trim().is_empty() || !text[block.body..first].trim().is_empty() || !text[last..block.close].trim().is_empty();
    if !others {
        return Some(block_removal(text, block));
    }
    let mut to = last;
    if first == block.body {
        // As for one line: a block that opens with a blank line is no block to the parser.
        let blank = kept.len() - kept.trim_start_matches([' ', '\t', '\r', '\n']).len();
        kept.drain(..blank);
        if kept.is_empty() {
            for line in text[to..block.close].split_inclusive('\n') {
                if !bare(line).bytes().all(|b| b == b' ' || b == b'\t') {
                    break;
                }
                to += line.len();
            }
        }
    }
    Some((first, to, kept))
}
